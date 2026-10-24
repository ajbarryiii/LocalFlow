# W0 benchmark harness: design

Status: revised after sol-loop round 1 (2026-10-21; r1 findings and responses
in RESULTS.md). Owner: W0. Implements the
Benchmark section of `CONTRACT.md`. Every number below that is a guess says so.

The harness is the yardstick for W1-W3, so it is built to be (1) realistic
enough that a scorer that wins here would win on AJ's desk, (2) exactly
reproducible from a committed command and hashed inputs, and (3) honest about
what it cannot measure.

## 1. Hypotheses the harness must be able to test

The harness itself makes no claim about scorers. It must make these questions
answerable, with speaker-level uncertainty:

- H1. A scorer removes a material fraction of interferer words (primary metric:
  interferer words kept at the 0.5 % target-word budget) in S1-S4.
- H2. The same scorer does not harm clean dictation (S0 WER increase < 0.1
  points absolute, the guardrail).
- H3. Performance depends on enrollment size (3/10/30), contamination (0/20 %),
  and device match.
- H4. Performance differs between overlap and non-overlap regions (we expect
  overlap to be much harder: the word-level rule cannot split a word).

The harness's own falsifiable claims, checked in `RESULTS.md`:

- C1. Oracle frame labels reach the ceiling: the oracle keeps no more than a few
  percent of interferer words outside overlap (failures there would mean labels
  or attribution are wrong).
- C2. Keep-everything reproduces unfiltered WER exactly.
- C3. Parakeet's WER on the dry dev-clean utterances, with our normaliser, is in
  the published range (about 1.7-2.0 %), and S0 WER is close to it (S0 adds
  mild reverberation, colouring and 15-40 dB SNR noise, so a small increase is
  expected; more than about +1 point would mean the S0 rendering is unrealistic
  or broken).
- C4. Rendered levels: SIR and SNR measured on the returned components equal the
  requested values (to 0.01 dB), and mixture == sum of components.
- C5. Label fractions per scenario are plausible (section 5) and the forced
  alignments agree with Parakeet word spans on dry speech (fraction of
  Parakeet word-span frames labelled active >= 0.9; fraction of active frames
  within 0.1 s of a Parakeet word span >= 0.9). The pre-registered thresholds
  were stated for the energy rule; on the dev pilot that rule scored 0.892 and
  0.990, failing the first marginally, which is part of why it was replaced.

What would change our mind about the harness: C1 failing (labels/attribution
broken); C3 failing (normaliser or ASR path broken); S0 WER > dry WER + 1 point
(S0 rendering too harsh); an interferer-word count per S1-S4 mixture near zero
(Parakeet ignores the interferers, so the primary metric would be undefined at
our SIRs and the ranges must be revisited, on dev only, before freezing).

## 2. Data and splits

Speakers: `lfspk.splits` (train-clean-360 / dev-clean + dev-other (73
speakers, since 86ef446) / sealed test-clean + test-other). Targets and speech
interferers of a mixture come from the same split. Every auxiliary corpus gets
an equivalent three-way split so that the sealed test set uses rooms, noises
and music unseen in training. LibriSpeech indexes record the subsets they were
built from and are refused if `SPLIT_SUBSETS` changes (r1 #3).

| corpus | use | split unit | rule |
|---|---|---|---|
| own simulated room bank (pyroomacoustics) | every RIR of the primary (coherent) mode; one of three pools in the secondary (mixed) mode | room | generated separately per split from split-specific seeds (train 1200 rooms, dev 150, test 150) |
| OpenSLR 26 simulated RIRs (small + medium rooms) | secondary mode only | room | stable hash of room id: <10 test, <20 dev, else train |
| OpenSLR 28 real RIRs (RWCP, REVERB, AIR) | secondary mode only (REVERB "near" 0.5 m positions serve as measured near-field) | recording room | explicit room lists (`REAL_ROOM_SPLIT`) |
| BUT ReverbDB (real, CC BY 4.0, already on disk) | secondary mode only | room (9 rooms) | explicit: 7 train, 1 dev, 1 test |
| DEMAND (CC BY-SA 3.0, on disk) | room ambience (S0-S4) | whole environment (r1 #10) | stable-hash ranking of the 6 indoor environments: first test (OHALLWAY), second dev (OOFFICE), rest train |
| SLR28 isotropic noises | room ambience | recording room | same room assignment as its RIRs |
| MUSAN noise + SLR28 point-source noises (MUSAN-derived) | noise events (S1) | file, keyed by MUSAN basename so duplicates land together | stable hash: <10 test, <20 dev, else train |
| MUSAN music (no-vocals only) | TV music bed | file | same hash rule |
| MUSAN speech, us-gov subset | not used since mix review r4 (TV speech is LibriSpeech only, so every speech label comes from a forced alignment) | file | same hash rule |

MUSAN's LibriVox speech is excluded entirely: it may contain LibriSpeech
readers, which would let a test speaker leak into training or appear as their
own interferer. us-gov (public-domain government recordings) was used for TV
speech until review r4 and is now dropped.
Music with vocals is excluded from the TV bed because sung words have no honest
activity label (section 5); the TV programme's speech is always a labelled
speech track.

LibriVox projects are not held out across splits (r1 #9): LibriSpeech's own
splits are by speaker, and train and dev share 71 project ids (other readers
of the same books). Shared projects mean shared text and production style, not
shared voices. Policy: accept it, and report a secondary check on dev targets
whose test project never occurs in train (`test_project_in_train` in the plan
record).

Licences (details and hashes in `data/PROVENANCE.md`): LibriSpeech CC BY 4.0;
OpenSLR 26/28 Apache 2.0 (the real RIRs inside SLR28 come from RWCP, REVERB and
AIR, whose original terms are checked and recorded separately); BUT ReverbDB CC
BY 4.0; DEMAND CC BY-SA 3.0; MUSAN CC BY 4.0 overall with per-file licences for
music checked from its `LICENSE` files (anything non-commercial is flagged and
excluded).

## 3. Rendering model

All audio is 16 kHz mono float32. Every mixture is the exact sum of returned
components:

    mixture = target_image + sum_k interferer_image_k + noise_image

Each component is rendered as `dry source -> (channel) -> RIR -> device
colouring -> level`, then a common gain keeps the mixture peak <= 0.95 (the
same gain is applied to every component, so SIR/SNR are unchanged). Device
self-noise is part of `noise_image`. Paired variants (S0-S4 of one seed and
target in a frozen set; the clean and contaminated twins of an enrollment
dictation) are rendered together by `render_paired` with **one** limiter gain,
the smallest any variant needs, so their target and noise components are
bit-identical (S1's noise differs by design: its own SNR range and events; S3
re-times the target). The base random stream (target, placement, room, level,
ambience, SNR quantile) depends on the seed only, never on the scenario or on a
retry; only the scenario stream is re-drawn when an interferer has too little
speech (r1 #5).

Levels are set on the images at the microphone, not on dry sources:
- active level of a component = 10 log10 of the mean square over the frames in
  which its dry source is active (section 5), so SIR does not depend on how much
  of the mixture the interferer occupies;
- target active level ~ U[-34, -20] dBFS (guess for a laptop dictation level;
  the energy baseline's absolute thresholds make this matter, so it is stated);
- SIR_k = L_target - L_interferer_k;
- SNR = L_target - L(acoustic noise), the mean square over the whole mixture
  of ambience plus (S1) the noise event, scaled jointly; the event sits
  U[0, 10] dB above the ambience over its span. Device self-noise is added at
  its own absolute level on top; `snr_total_db` (target over all of
  `noise_image`) is recorded beside the requested and measured acoustic SNR
  (r1 #4).

RIRs are delay-normalised: samples before the direct-path peak minus 1 ms are
dropped, so dry activity labels line up with the reverberant image to within
1 ms (true acoustic delays of 1-5 m are 3-15 ms, below one frame's
consequence for word decisions). RIR gain is irrelevant because levels are set
afterwards; the RIR contributes reverberation (DRR, T60) only. Tails are cut
where the energy decay curve reaches -60 dB, at most 1.0 s.

### 3.1 Geometry and SIR by scenario

Level ranges come from a critical-distance model (the level at the mic from a
source at distance r is proportional to 1/r^2 + 1/r_c^2) with r_c of 0.5-1.0 m
for furnished rooms with T60 0.3-0.8 s, plus vocal-effort spread of about +-5 dB
(Pearsons, Bennett and Fidell 1977: casual to raised voice spans ~10 dB). For a
target at 0.25-0.6 m this gives target-over-talker advantages of roughly 3-8 dB
at 1-3 m and 4-10 dB at 2-5 m; reverberant-field dominance is why the advantage
saturates. Everyday SNRs reported by Smeds, Wolters and Rung (2015) are mostly
+5 to +15 dB, which brackets the ranges below. These are modelled guesses, not
measurements; no measurement of AJ's room or laptop exists, and recording one is
out of scope (privacy rule).

| id | interferers | dry source | channel | interferer RIR | SIR per interferer (dB) | timing |
|---|---|---|---|---|---|---|
| S0 | none | - | - | - | - | - |
| S1 office | 1/2/3 with p .5/.3/.2, distinct speakers | LibriSpeech segment of U[1.5, 8] s cut from a random point of one utterance | none | far field 1.5-5 m | U[3, 18] | each segment at a uniform offset in the mixture (partial overlap) |
| S2 TV | 1 programme | LibriSpeech dialogue of 1-2 other speakers (utterances concatenated with 0.2-0.8 s gaps), plus a MUSAN no-vocals music bed with p .5 at 5-15 dB below the speech | broadcast compressor + TV loudspeaker colouring | far field 1.5-4 m | U[0, 15] | continuous: covers the whole mixture |
| S3 call | 1 far-end talker | LibriSpeech, 1-2 turns of U[1.5, 6] s | narrowband (p .4: 300-3400 Hz, 8 kHz G.711 mu-law) or wideband VoIP (p .6: 50-7000 Hz, transform-codec-like quantisation, 0-3 % 20 ms packet loss with repetition concealment), then laptop-speaker colouring | same room, 0.08-0.25 m from the mic | U[-6, 9] | turn-taking: the target is split at its longest internal pause and a turn inserted; each turn starts at the end of the preceding target part plus U[-0.8, 0.5] s (negative = overlap); with p .3 a turn also precedes the target |
| S4 second dictator | 1 speaker, same sex as the target with p .6 | 1-2 consecutive LibriSpeech utterances of one speaker | none | 1-3 m | U[-2, 10] | starts U[-2, 2] s from the target start: frequent overlap |

RIR modes (r1 #2). **Primary, `coherent`**: every source of a mixture is in the
target's simulated room (one bank room per seed): the target at its near-field
role, other talkers, the TV and noise events at far roles (distinct positions
where the room has enough in range; bank far roles are stratified over 1-5 m),
call audio at the laptop-speaker role 0.08-0.25 m from the mic. Every situation
AJ described happens in one room, and nothing but geometry separates target
from interferer acoustically. **Secondary, `mixed`**: every source, the target
included, independently draws its RIR from another bank room, an OpenSLR 26
room (distance from the direct-path delay; near field <= 0.6 m) or a measured
REVERB 2014 room (near field 0.5 m, far field 2 m) with probability 1/3 each,
so RIR provenance (simulator vs measurement chain) is balanced across roles;
distances stay role-appropriate. Measured RIRs come only from REVERB because it
is the one measured family with near and far positions in the same rooms, so
both roles share one measurement chain (r2 #2); BUT ReverbDB, RWCP and AIR are
indexed but unused. Residual cues, disclosed: a headset target always uses the
bank (no other 2-5 cm responses exist), and REVERB far positions are all 2 m.
Mixed-mode results are secondary only; tau is calibrated on the primary.

Room noise in every scenario: DEMAND office/meeting/living/kitchen/hallway/
washing or SLR28 isotropic noise, SNR U[15, 40] dB in S0, S2, S3, S4 and
U[10, 25] dB in S1, where with p .5 a MUSAN noise event (through a far-field RIR
in the same room) is added U[0, 10] dB above the ambience measured over the
event's own 1-5 s span (r2 #3).
Device self-noise: pink noise at U[-72, -62] dBFS (built-in) or U[-82, -72]
dBFS (headset); guesses.

Lead/tail: 0.3-1.0 s of room noise before and after the target (a dictation
starts and ends with key handling), and target utterances of 3-20 s.

### 3.2 Colourings

All are parametric because no measured responses of real devices are available
to us; parameters are drawn once per user (seeded by split, speaker id and
device) so a user owns one laptop and one headset, as in reality.

- Built-in laptop mic: 2nd-order high-pass at U[100, 200] Hz, presence peak
  U[0, +5] dB at U[2.5, 5] kHz (Q 1), high shelf U[-6, 0] dB above 6 kHz.
- Headset: high-pass U[60, 100] Hz, low-pass U[6.5, 7.5] kHz (Bluetooth
  wideband voice band), and a proximity-effect low shelf U[0, +6] dB below
  200 Hz applied to the target image only (proximity effect is a near-source
  property). Headset target near-field RIR: 0.02-0.05 m.
- TV loudspeaker: 4th-order high-pass U[80, 150] Hz, two random resonances
  (U[200, 4000] Hz, +-4 dB, Q 1-3), soft clipping (tanh) at mild drive.
- Laptop loudspeaker: 4th-order high-pass U[250, 450] Hz, resonance +6..+10 dB
  at U[0.8, 2.5] kHz, stronger soft clipping.

### 3.3 Device mismatch

Frozen test mixtures use the built-in microphone. The enrollment stream is
rendered under built-in (matched) or headset (mismatched) colouring and
near-field geometry. The SIR distribution is the same for both devices on
purpose: the variant isolates the voiceprint's channel robustness; a real
headset's level advantage would only make interference easier. The generator
accepts either device for mixtures, so a headset-test variant can be added.

## 4. Mixing API (for W3 and the frozen sets)

`lfspk/harness/mix.py`. Deterministic: a mixture is a pure function of
`(split, scenario, seed, device, target_utterance, corpus index version)`.
Seeds are derived with `numpy.random.SeedSequence` from stable SHA-256 hashes,
never Python `hash()`. Exact field lists are recorded in CONTRACT.md NOTES.

- `Mixture`: `audio`, `target` (image), `target_dry` (placed dry track),
  `interferers` (list of images), `interferers_dry`, `noise`, `labels` (uint8 per
  10 ms frame, 0/1/2/3), `target_active`, `interferer_active` (bool per frame),
  `meta` (dict: ids, transcripts, offsets, gains, SIR/SNR requested and measured,
  RIR ids, colouring parameters, overlap fraction, split).
- `MixtureGenerator(split, corpus=None, speakers=None, pin_sources=False)`:
  `.render(scenario, seed, target=None, device="builtin", rir_mode="coherent")`,
  `.render_paired(scenarios, seed, ...) -> {scenario: Mixture}` (one limiter
  gain), `.speaker_plan(speaker)`, `.enrollment_streams(plan, set_seed, device,
  contaminator=None) -> (clean, contaminated)`. `speakers` restricts every
  randomly drawn speaker role to a pool (a dev half). With `pin_sources`, meta
  records the SHA-256 of every input file read (target and interferer
  utterances, ambience, music, events, RIR files and bank NPZs) so a frozen set
  is verifiably regenerable (r1 #6); the index hashes cover the JSON indexes,
  the bank metadata and CHAPTERS.TXT.
- `MixtureSampler(split, base_seed, scenarios, weights, p_headset, speakers,
  p_mixed_rir)`: an indexable, length-unbounded stream for training
  (`sampler[i]` is deterministic).

## 5. Frame labels

Labels come from the dry source tracks (before RIR and colouring), and since
mix review r4 from **word-level forced alignments** of the reference
transcripts (`lfspk/harness/forced.py`). Four review rounds showed that any
energy threshold on a dry track can be tricked by some combination of padding,
dither, room tone and level; an alignment is independent of all of them by
construction.

- Aligner: CTC forced alignment (`torchaudio.functional.forced_align`) of the
  LibriSpeech transcript on the emissions of torchaudio's
  `WAV2VEC2_ASR_BASE_960H` (fairseq wav2vec 2.0 base fine-tuned on LibriSpeech
  960 h; MIT), 20 ms emission frames. Its training data includes
  train-clean-360, so alignments may be slightly better on train than on dev
  and test (dev and test are not in its training data). The public
  Montreal-Forced-Aligner alignments of LibriSpeech (CorentinJ) carry no
  licence and are not used.
- Transcript normalisation for the CTC vocabulary: upper case; characters
  outside {A-Z, '} dropped (LibriSpeech has none); words separated by the
  word-boundary token; tested.
- Pre-registered label rule (`forced.words_to_frames`, integer milliseconds):
  gaps between consecutive words strictly shorter than **200 ms** are merged,
  then a 10 ms frame is active iff it intersects a merged interval padded by
  **40 ms** each side; everything else (pauses of 200 ms or more, room tone,
  padding) is inactive. Why not the 20 ms padding first proposed: CTC
  alignments are peaky. Against Parakeet TDT word spans (an independent model
  family and decoder; itself not ground truth, 80 ms-quantised) on a
  40-utterance dev smoke, CTC word starts were a median 24 ms later and ends
  47 ms earlier, and between consecutive correctly matched words CTC left a gap
  of 40 ms or more in 95 % of cases (median 80 ms) where Parakeet left one in
  19 % (median 0 ms): holes inside fluent read speech. Frame agreement with the
  Parakeet spans rises from 0.847 (pad 20 ms, no merge; recall of Parakeet
  frames 0.840, precision 0.950) to 0.897 (merge 200 ms, pad 40 ms; 0.927,
  0.934). The 200 ms figure is the conventional boundary between articulatory
  and hesitation pauses (Goldman-Eisler 1968); Campione and Veronis (2002) use
  it too but report that real silent pauses shorter than 200 ms exist, so the
  rule is a convention, not a fact about every gap. The 40 ms pad is two CTC
  frames. Hand check: e.g. 84-121123-0001, CTC "BUT[0.30-0.40] IN[0.46-0.50]
  LESS[0.56-0.72] THAN[0.74-0.84] FIVE[0.92-1.10]" vs Parakeet "But[0.16-0.32]
  in[0.40-0.56] less[0.56-0.72] than[0.72-0.96] five[0.96-1.12]".
- **Known cost of the merge rule (r5 #4), disclosed rather than fixed:** a
  genuine target pause shorter than 200 ms becomes target speech, so a short
  interferer word inside it is labelled overlap rather than interferer-only;
  the rule is symmetric between speakers but inflates the overlap class. No
  independent pause annotation exists for these corpora and none is made.
  Mitigations: (a) every frozen set also stores sensitivity labels without
  merging (same 40 ms pad), and the evaluator reports every frame-level metric
  (AUC, EER) under both; (b) the word-level metrics, including the primary
  one, do not use frame labels at all, except the oracle ceiling (and word
  regions, overlap vs single, which use the primary labels); attribution of
  unaligned words uses them only for the fallback "majority label" step.
- Pre-registered fallback: an utterance whose CTC alignment fails gets word
  intervals from Parakeet TDT timestamps on the dry utterance (80 ms steps);
  an empty result is still a failure. Counts per split are reported (expected
  about zero). An utterance without a non-empty alignment is an error at render
  time, never silently labelled.
- Every speech source in the benchmark is LibriSpeech (MUSAN us-gov was dropped
  from the TV programme for label uniformity), so every speech label comes from
  an alignment.
- The energy rule of earlier rounds (`activity.activity`) remains only as a
  diagnostic: its frame agreement with the alignments is reported on dev.

Validation on dev (claim C5, revised): frame agreement of alignment activity
with Parakeet word spans on the dry utterances, the energy diagnostic's
agreement, and a hand check of a few utterances' word intervals beside their
transcripts (RESULTS.md).

Reverberant tails are not speech. Mixture labels: `label = t + 2 i`, with t
the target activity and i the OR of all interferer activities. Music beds and
noise have no activity. Plausible fractions (checked, not tuned): S0 label 2
and 3 exactly 0; S2 interferer activity > 60 % of frames; S3 overlap (label 3)
< 15 %; S4 overlap > 25 % of target-active frames.

## 6. Enrollment protocol

Per target speaker of a split, utterances are partitioned once
(`MixtureGenerator.speaker_plan`):
- A chapter is not a recording session: chapters of one LibriVox project
  (CHAPTERS.TXT) probably share microphone and room, so channel cues survive
  chapter separation. The test chapter is chosen (seeded) among chapters with at
  least 10 qualifying targets, preferring chapters for which the speaker has at
  least 30 enrollment-length utterances in *other projects*, else the most such.
- Test targets: 10 utterances of 3-20 s from the test chapter (relaxed to
  2-30 s, flagged, if no chapter has 10).
- Enrollment stream: up to 30 utterances of 2-20 s, ordered by separation:
  other projects first, then other chapters of the same project; seeded order
  within each group. A multi-chapter speaker never enrolls from the test
  chapter: if other chapters hold fewer than 30 utterances the stream is
  shorter (flag `enroll-short:n`) and that speaker's targets have no k = 30
  result (they are counted, not padded). Each dictation carries its relation
  (`cross_project`, `same_project_cross_chapter`), and each (target, k) the
  weakest relation among the first k dictations (`SpeakerPlan.relation_at(k)`);
  every result is reported pooled over these two and split by them.
- Single-chapter speakers (9 of 40 in dev-clean, 15 of 73 in test) can only enroll from their
  test chapter (utterance-disjoint, relation `same_chapter`, beyond the
  contract's fallback). Their targets are excluded from headline numbers and
  reported separately: same-chapter enrollment shares the recording session
  with the test audio and would flatter a scorer that keys on the channel.
- Each enrollment dictation is rendered like S0 (own room, near field, device
  colouring, ambience). Contamination: in each block of 5 dictations, one seeded
  position is contaminated with an S4-like interferer. Exactly 20 % at 10 and
  30, expected 20 % at 3. The clean and contaminated streams share utterances,
  order and rendering; contaminated twins are rendered with their clean twin
  (one limiter gain) and differ only by the added talker. In dev the
  contaminating talker comes from the *other* dev half, so a contaminator is
  never also an evaluation interferer in the same half; in test, from the whole
  split. Every dictation's meta carries its relation and index.
- The scorer sees `enroll(first 3)`, then `update` for dictations 4..30 in
  order; results are read at 3, 10 and 30.

Conditions: {3, 10, 30} x {clean, 20 %} x {matched, mismatched} = 12. The
pre-stated headline is (10, clean, matched); the others are robustness results.

## 7. ASR cache and word attribution

Parakeet TDT 0.6B v2 (`lfspk.paths.PARAKEET_V2_NEMO`, NeMo, greedy TDT,
FP32, word timestamps) transcribes, once per frozen set, (a) every mixture,
(b) every dry target track and dry interferer speech track as placed in the
mixture timeline (for the target-dropout check and the pseudo-reference
cross-check), and (c) the dry dev utterances (claim C3; dev-clean and dev-other
reported separately). GPU shared lease; batches are length-sorted; the cache is
resumable and tolerates an incomplete final record.

References (revised after the mix stage moved to forced alignments):
- Target and every interferer: the true LibriSpeech transcript words with
  their CTC-aligned times, mapped onto the mixture timeline through the
  placements each mixture records (utterance, slice, offset; `refs.placed_words`).
  An interferer word cut by a segment boundary or the mixture edge counts if at
  least half of its aligned interval is audible; target words are never cut.
- Cross-check only: attribution recomputed with Parakeet transcripts of the dry
  interferer tracks as pseudo-references; the share of hypothesis tokens
  attributed to the same source is stored per mixture and reported.

Normalisation (both sides): Unicode NFKD to ASCII, lower case, hyphens to
spaces, keep [a-z0-9'], strip edge apostrophes, digit tokens to words
(cardinals; 4-digit years 1100-1999 as two pairs).

Attribution of each mixture hypothesis word h with span [hs, he]:
1. For each source r (target, each interferer), a Levenshtein alignment of the
   whole hypothesis against r's reference where a pair may be matched or
   substituted only if `[hs - 0.5, he + 0.5]` overlaps the reference word's span
   (time-compatible; 0.5 s since dev-v1, see section 8); otherwise it must be an
   insertion plus a deletion. Lexicographic cost: fewest edits (1/1/1), then
   most exact matches, then the smallest summed start-time difference of paired
   words (integer ms, capped at 10 s), so a repeated word pairs with its closest
   occurrence; remaining ties broken match > substitution > deletion > insertion.
2. h is attributed to the source where it is an exact match; if several, the
   one with the larger time overlap, then target. Otherwise to the source where
   it is a substitution, with the same tie-breaks.
3. An unaligned h is attributed by the frame labels over its span: majority
   label 2 -> interferer; majority of frames with the target active (1 or 3) ->
   target insertion; else "other".

Target WER (before, after, oracle) is the time-constrained alignment of the
(kept) hypothesis against the target reference, so interferer words count as
insertions. The unconstrained jiwer WER is also reported for C3.

## 8. Decision rule, calibration and metrics

Contract rule (amended 2026-10-21, e4782a5): keep h iff the mean frame score
over its frames is >= tau, where its frames are the Parakeet span widened by
80 ms on each side and clipped to the recording: `floor((hs - 0.08) / 10 ms)
.. ceil((he + 0.08) / 10 ms) - 1`, at least one frame (`align.decision_span`,
applied in exactly one place, refs.py, for every scorer and the oracle). On
dev-v1, 0.64 % of correctly recognised target words had unwidened spans wholly
in labelled pauses (Parakeet timestamps shifted), which forced tau to 0 even
for the oracle. Oracle ceilings at 0, 50 and 200 ms widening are reported as a
sensitivity block. The S0 WER increase is a reported guardrail metric with its
CI and the oracle's value, not pass/fail (the pooled 0.5 % budget and a
0.1-point S0 limit can conflict).

Alignment tolerance: 0.5 s (was 0.2 s): on dev-v1, S0 target WER under the
time-constrained alignment was 3.89 % at 0.2 s, 3.07 % at 0.5 s, equal to the
untimed WER; among minimum-edit alignments the one with most exact matches is
chosen. Frame statistics (AUC, EER, both label variants) are computed at the
headline condition only (cost); word-level metrics for every condition.

Calibration and application are separate (eval r1 #2). `evaluate run` on a
dev set calibrates and writes `calibration.json` (tau per condition and the
oracle's, scorer configuration, set hash, git; content-hashed). `evaluate
apply --calibration ...` evaluates any set, the sealed test set in particular,
with those taus held fixed in the point estimate and in every bootstrap
resample; calibrating on a set whose split is test raises.

Calibration of tau, per scorer and per enrollment condition, on dev, pooled
over S0-S4 of the primary (coherent) mixtures of headline targets: let N be the
number of target reference words and m the sorted mean scores of hypothesis
words attributed as exact target matches; tau is the largest threshold that
removes at most 0.005 N of them (ties at tau are kept). If all of them fit in
the budget, tau is set just above the highest of them. If there is none, the
condition is uncalibrated: it is reported as such, its artefact entry is null,
and apply reports it as "not evaluable (uncalibrated on dev)" rather than
removing everything (orchestrator decision after eval r2). Saved scores carry
the scorer configuration and set identity; calibration export and apply refuse
scores of another configuration, and calibration runs on dev sets only. A secondary report
applies the headline condition's tau to every condition (what a product with
one threshold would do). Out-of-sample budget compliance on dev: a cross-fit
over the canonical dev halves (calibrate on A, measure on B, and back). The
removal budget is also reported per enrollment relation (cross_project,
same_project_cross_chapter) at the pooled tau, since the relations differ in
how well a voiceprint transfers.

Word-error accounting: WER after filtering holds the full hypothesis's
alignment fixed (removing a correct word adds a deletion, removing a
substitution leaves the count, removing an insertion removes an error), which
makes every metric additive per mixture and the bootstrap fast; it is an upper
bound on re-aligned WER, and the exact re-aligned value is reported at the
point estimate.

Uncertainty. 95 % percentile bootstrap (B = 2000, seed 0) over LibriSpeech
speakers of the evaluated set, all mixture roles jointly (contract, bb5629b):
each resample draws one multiset of speakers; a mixture counts with
multiplicity equal to the product of the draw counts of every distinct
LibriSpeech speaker audible in it (target, office talkers, TV programme
speakers whose speech survives the crop, call talker, second dictator), and is
dropped if any of them is not drawn. Each statistic is a ratio of sums over the
weighted mixtures, and tau is re-calibrated inside each resample. **Estimand
(r1 #8): the CIs are conditional on the fixed, seeded enrollment contamination
streams.** Contaminating talkers are not resampled; in dev they come from the
other half, so they never coincide with an evaluation interferer of the
evaluated half. Music and noise are not resampled either.

Selection. Configurations chosen as the best of several on dev are reported
with the selection accounted for: the canonical dev halves
(`lfspk.harness.halves.dev_halves()`: A 37 speakers for selection, B 36 for
reporting; stratified by subset clean/other, sex and session class =
`relation_at(10)`; deterministic hash order; lists in NOTES). Frozen dev
mixtures never cross halves. The evaluator's `--half A|B` restricts mixtures,
calibration and bootstrap to one half.

Secondary groupings reported at the headline tau: RIR mode `mixed` (section
3.1), targets whose test project never appears in train, same_chapter targets.

Metrics, per scenario, per region (overlap / non-overlap), per enrollment
relation and pooled:
- target WER before / after / oracle;
- interferer words kept (primary) = kept interferer-attributed words / all
  interferer-attributed words;
- target words removed = removed exact target matches / target reference words;
  S0 WER increase reported separately;
- frame ROC AUC and EER, target-active frames (1, 3) vs interferer-only (2):
  exact weighted rank statistics (ties count one half; EER interpolated at the
  crossing of the piecewise-linear ROC) at the point estimate and in each of
  the first 300 bootstrap resamples (W3's FrameRanks; eval r1 #1, #3);
- beside the primary metric: interferer words kept on mixtures without target
  dropout, target coverage (correctly recognised target words before
  filtering over reference words), and a sensitivity that counts tokens
  exactly matched by both the target and an interferer ("ambiguous", e.g. the
  same word said at the same time) as interferer words (eval r1 #6, #7);
- valid-resample counts per statistic (sparse strata lose resamples);
- `CostReport`, and CPU latency: median and p90 seconds per audio second of
  `score` on 30 fixed dev mixtures, and `update` latency, in a subprocess with
  no visible GPU and one thread for OpenMP, MKL, OpenBLAS and ONNX Runtime
  (refused otherwise; other backends' threads are configured, not verified).

Region of a word: overlap if at least half of its frames carry label 3 (for
reference words: their reference span; for hypothesis words: their hypothesis
span).

Baselines: keep-everything (score 1), oracle (score = 1 on label 1 or 3, else
0, calibrated like any scorer, and reported beside every scorer's results as
the ceiling), energy-only (an exact port of LocalFlow's
`ParakeetSilenceCompactor.isSpeech`, score 1 on speech frames; no profile).

Reporting details: frame scores are stored as float32 exactly as returned
(float16's spacing near 1 would tie confident scores where tau sits); every
fraction is shown with its absolute count (interferer words and mixtures per
scenario), so a "kept 10 %" of very few words is not over-read; frame metrics
appear under the primary and the no-merge labels.

ASR findings reported separately from filtering (sanity checks): interferer
words Parakeet transcribes per scenario, and **target dropout**: mixtures in
which Parakeet loses more than half of the target words (S + D over target
reference words) although the dry target alone transcribes with WER <= 10 %.

## 9. Frozen sets and sizing

Dev: 73 speakers x 10 targets x 5 scenarios = 3650 primary (coherent)
mixtures (about 10 h), plus the first 4 targets per speaker again in the
secondary (mixed) RIR mode, 1460 mixtures: 5110 in total. The same targets
appear in every scenario and are rendered as one paired group. Test: 73 x 10 x
5 + 73 x 4 x 5 = 5110, rendered and hashed but never scored or inspected by W0.

CI width estimate (to be checked on the energy baseline and oracle once
rendered): the primary metric's CI is dominated by between-speaker spread.
With about 59 headline dev speakers (73 minus 14 single-chapter) and an assumed
between-speaker SD of 0.15 in the kept fraction, the 95 % half-width is about
1.96 x 0.15 / sqrt(59) = 0.038 before the joint-role resampling, which widens
it (interferers are resampled too). Within-speaker noise with ~10 mixtures x
~15 interferer words (p ~ 0.3) is about 0.037 per speaker, already below the
between-speaker SD, so more mixtures per speaker buy little. Evaluation cost:
5110 mixtures x 12 conditions = about 170 h of audio to score; a scorer at 100x
real time per core needs 10 min on 10 cores (contaminated conditions reuse the
clean profile's scores while the stream prefixes agree, about a third of the
work at k = 3).

Format: `data/harness/sets/<set_id>/` with `manifest.jsonl`, mixture audio as
24-bit FLAC (decoded float32 is what scorers and ASR see), dry tracks as 16-bit
FLAC, labels as `.npz`, enrollment dictations as 24-bit FLAC. The content hash
is the SHA-256 of the sorted list of (relative path, file SHA-256). Scenario set
ids and hashes go to NOTES and `READY.json`.

## 10. Real acoustics (best effort)

AMI: only the validation (dev) headset segments are on disk (527 MB). An honest
check set needs headset and distant channels of the same meetings plus
word-level annotations and the official split. Deferred until the synthetic
harness is ready; a download request goes to the orchestrator first.

## 11. Risks

- Simulated colourings and SIR ranges are modelled, not measured. A scorer
  could exploit simulation artefacts (for example the absence of loudspeaker
  colouring in S4); the AMI check is the mitigation.
- The level of real laptop dictations is a guess; the energy baseline is
  sensitive to it.
- Pseudo-references for interferers inherit Parakeet's errors; attribution
  uses timing as well as text, which limits the damage.
- Word timestamps from TDT are coarse (80 ms) and sometimes shifted into pauses; the 0.5 s alignment tolerance and the contract's 80 ms widening of decision spans absorb it (oracle sensitivity at 0/50/200 ms).
- The 0.5 % budget is calibrated and evaluated on the same dev words; the
  cross-fit estimate shows the optimism.
- S2's TV speech is read audiobook speech (LibriSpeech), less broadcast-like
  than real TV (no presenter prosody, no studio mixing beyond our compressor and
  music bed): a realism limitation of S2.
- Labels are CTC word intervals, merged across gaps under 200 ms and padded
  40 ms: boundaries are good to a few 20 ms frames; within-sentence pauses of
  200 ms or more are label 0.
- The secondary (mixed) RIR mode places sources in different rooms by design;
  only the primary mode is physically coherent.
- Contamination talkers are fixed; CIs are conditional on them.

## 12. Packages

No new packages: numpy, scipy, soundfile, pyroomacoustics (already installed)
for rendering; NeMo via `./python-nemo` for Parakeet. A real Opus codec (ffmpeg)
for S3 would be more faithful than the transform-codec stand-in; requested from
the orchestrator as an option, not assumed.

## 14. Front ends that change the transcript (contract 7c7c1fa; W5 DESIGN 9-10 at f7d74ba normative)

Status: 14.1 frozen-set design (W0); 14.2 `evaluate frontend` design for
review (W0F, 2026-10-22); boundary with W5 agreed as in 14.2 fe-0 and fe-7.

### 14.1 Noise-only twin sets (W5 9.4)

`noise-dev-v1` / sealed `noise-test-v1` (`frozen render-noise --pair dev-v1|test-v1`):
the first 4 targets of every speaker plan, families {noise, music} x acoustic
SNR {20, 10, 5, 0} dB = 2336 mixtures per set. Each mixture is the S0 render of
the paired set's seed for that target (`mix.render_noise_group`: same target,
placement, room, level, ambience segment, device and self-noise). The paired
S0's whole background (its ambience, DEMAND or SLR28 isotropic noise at S0's own
SNR, and device self-noise) is kept bit-identical; the manipulated factor is
the added MUSAN source, one whole file through a far-field RIR of the same room
(1.5-4 m) and the device colouring, scaled alone so that the active target
image over the source image is the stated SNR (self-noise excluded; noise-r2
#1). The inherited ambience SNR is recorded per mixture and its distribution
reported. One MUSAN file per family across its four SNRs. `noise`: a MUSAN
noise file (events and continuous noises alike, dev split); `music`: a no-vocals music
file through the TV loudspeaker colouring. The limiter gain is the paired S0-S4
group's (`render_paired(SCENARIOS)`), so every variant's target component is
bit-identical to dev-v1's S0 (verified at HEAD: S0-84-00's meta reproduces the
frozen manifest exactly). A variant that would exceed the 0.95 peak limit at
that gain re-draws its family's MUSAN file (all four SNRs together) deterministically; the count is recorded per
mixture (`noise_spec.reselections`) and reported per family and SNR.
Labels are S0's (no interferer). Enrollment
streams are rendered with the paired set's enrollment seed, so they equal
dev-v1's. Ids `N<n|m><snr>-<speaker>-<jj>`, scenario `N`. Same freezing,
hashing and NOTES rules as dev-v1; the test twin is sealed.

### 14.2 `evaluate frontend`: design (W0F, 2026-10-22; closed at 9ef37f9 after 4 sol rounds)

Implements the contract's "Front ends that change the transcript" and W5
DESIGN 9.2-9.6 and 10.2-10.3 (normative, f7d74ba, plus its amendments) on the
interface W5 closed at f2638ba. Numbered items are for review references
(fe-#). Nothing here changes the scorer evaluation path (fe-15).

**fe-0 Files.** `lfspk/harness/tmetrics.py` holds the transcript metric
definitions, shared with W5 (fe-7). `lfspk/harness/frontend_eval.py` holds the
stages, the caches, the pairing, the reports and the latency CLI. Tests live in
`tests/test_W0_frontend.py` and `tests/test_W0_scorer_regression.py`.
`evaluate.py`, `metrics.py`, `align.py`, `refs.py`, `asr.py` and `frozen.py`
are imported only, never edited. W5's `api`, `frontend`, `nemo_hook`,
`constants` and `cachepin` are used as closed at f2638ba.

**fe-1 Inputs.**
- The frozen set: dev-v1, or noise-dev-v1 once it is frozen.
- B: the harness's cache `data/harness/asr/<set>/asr.jsonl` and
  `asr.meta.json`, plus `words.jsonl`. All of these are read-only.
- A front-end factory: `MODULE:CALLABLE` plus string kwargs, as for scorers.
  The concrete one is `lfspk.extract.harness_frontend:make
  checkpoint=...`.
- The word-filter candidates: score directories written by `evaluate run`.
  Each is verified with `check_score_identity` and its own half's expected
  keys, and the directories are grouped by scorer identity. The candidate
  list, W1's and W3's selected configurations, is fixed by the orchestrator
  before any half-A fit and recorded in the selection artefact (fe-10).
- `theta_b` for C3 and C4 comes only from W5's artefact: `theta_b.json`
  beside the checkpoint, naming its SHA-256 and written by `lfspk.extract.calibrate
  theta` on held-out train speakers. The configurations are built with
  `fe.config("C1".."C4")` (W5 12c176c), which raises if theta_b is missing.
  There is no command-line theta_b.

**fe-2 Rows, conditions, headline.** Stages A and B always cover every row of
the set: both halves, both RIR modes and every enrollment relation. That gives
one persistent cache, and the secondary groupings exist. Computing half-B
transcripts reveals nothing to the selection: `select` restricts rows to half A
before it computes any quantity, and that restriction is tested. The expected keys of a
condition are the (condition, mixture) pairs of `evaluate.expected_score_keys`
for that condition: a condition exists for a speaker iff the speaker's
enrollment stream reaches k. The headline condition is (builtin, clean, 10).
Metrics are computed on the headline subset, as in `compute_metrics`: coherent
rows whose `relation_at[k]` is cross_project or same_project_cross_chapter.
Same_chapter rows and mixed-RIR rows are point-estimate secondary groupings.

**fe-3 Stage A (CPU, `./python`, no GPU lease).**
- A process pool works per speaker. Each worker builds the front end once and
  sets one torch thread; the thread count is part of the identity.
- The profile for condition (device, contaminated, k) is
  `enroll(stream[:3])` followed by `update` for `stream[3:k]` in order. This
  is the exact call sequence of `evaluate._score_speaker` for that condition.
- Then `analyse(profile, audio)` runs for each mixture, with the audio from
  `util.load_audio`. That is the loader B's ASR job used, so stage A, stage B
  and B see identical samples (tested).
- Output, at the location W5 asked for (W5 10.2):
  `runs/W5/masks/<checkpoint-sha12>/<set>/<device>-<clean|contaminated>-<k>/masks/<mixture>.npz`
  holding {log_mask float16, u float32}. A front end without a checkpoint
  SHA-256 uses the first 12 hex digits of its identity hash. `check_mask_output` runs before
  saving.
- `IDENTITY.json` holds kind, factory spec, sorted args, `fe.identity()` and
  its SHA-256, set id and hash, condition, protocol string, torch
  threads (1, which must equal `identity()["analyse_threads"]`: W5 measured
  log_mask differing by up to 1e-5 between thread counts), the SHA-256 of
  the stage-A code unit `lfspk/harness/fe_stage_a.py` (kept in its own module
  so that report or metric edits do not invalidate stored masks), and its own
  hash. `identity()` hashes all of
  `lfspk/extract/*.py` and includes theta_b, so any W5 code edit, and the
  theta_b calibration, change the stage-A key. W5 fixes theta_b before any
  dev evaluation (W5 7), so stage A runs after theta_b exists.
  `prepare`-style claiming applies, as in `evaluate.prepare_score_dir`: a
  directory holding another identity is refused, any `.npz` without an
  identity is refused, and a stale `COMPLETE.json` is cleared before writing.
- `COMPLETE.json` is written last. It holds the identity hash, n_keys,
  keys_sha256, and per key the array hash: SHA-256 of `log_mask` float16
  bytes, then `u` float32 bytes, with shapes. It also holds the torch thread
  count each worker actually observed (`torch.get_num_threads()` read inside
  the worker after each `analyse`). Saved keys must equal the expected keys
  exactly, and every observed count must be 1, or the run fails.
- Persistence follows W5 10.2.
  - Only the headline condition's arrays are kept.
  - A non-headline condition's arrays are deleted with `purge`, after its
    stage B is complete for every configuration in use. IDENTITY.json and
    COMPLETE.json, with the per-key hashes, are kept, and PURGED.json is
    added.
  - `stage-a` refuses to start a non-headline condition while another
    non-headline condition's arrays exist unpurged, so conditions are
    processed one at a time.
  - Regenerating a purged condition must reproduce every recorded array hash,
    or it is refused.
- C1-C4 differ only in w(t), so they share one stage A.

**fe-4 Stage B (GPU, `./python-nemo`, `--needs gpu:shared`, memory-fraction
cap).**
- One cache per (stage A, weights, configuration), at
  `OUT/stageB/<weights>/<condition>/<config>/asr.jsonl` plus `asr.meta.json`
  and `COMPLETE.json`. OUT defaults to `runs/W0/frontend/<front-end
  name>/<set>/`. Selections and reports go to `OUT/select-A/` and
  `OUT/report-<half>/`.
- The identity is `cachepin.frontend_cache_identity(...)`.
  - Inputs: stage A identity hash; `InferenceConfig.to_dict()` including
    theta_b; the ASR identity (`asr.cache_identity()` for `base`); B's
    `asr.meta.json`; `nemo_hook.hook_code_sha256()`; `batched` with batch
    size 16. That function refuses when stage B's ASR identity differs from
    B's.
  - Added top-level fields: set id and hash, condition, `weights`
    (`base` | `m1`), the chunk rule, and the `frontend_eval.py` hash.
- Bypass is decided with `frontend.bypassed` on the stored arrays. A bypassed
  mixture is never transcribed. Its entry is `cachepin.pin_bypass(B record,
  B identity, frozen audio SHA-256)` plus `mask_sha256`. The frozen audio hash
  is the line for `mix/<id>.flac` in the set's `CONTENT.sha256`, read-only.
  B's per-entry `audio_sha256` is the same file hash.
- Masked mixtures are sorted by id and cut into fixed chunks of 256. Each
  chunk goes to `nemo_hook.transcribe_masked(model, audios, masks, config,
  batch_size=16)`, which length-sorts and batches it and checks the model's
  front-end constants against the pinned ones.
  - Each masked entry: {key `mix:<id>`, audio_sha256, text, words,
    `bypass`: false, `mask_sha256`, `chunk`}.
  - Chunk membership is a pure function of the masked key list, so every
    batch's composition is reproducible.
  - A chunk is written as one block after its transcription. On resume, a
    chunk with fewer entries than expected (a crash mid-write) is removed
    from the file and redone whole, never topped up. Resumed and
    uninterrupted runs therefore batch identically.
  - Resume otherwise follows `asr.check_resume`: the identity must be equal,
    and each entry's audio and mask hashes must equal the current ones.
- B* (W5 9.1, diagnostic): the same path with log_mask = 0, u = 0 and C1
  (w = 1, no bypass). There is no stage A; the identity's stage-A field is the
  hash of {"kind": "bstar"}.
- `m1` (W5 9.5) needs its own B cache, B_m1: the same worklist keys,
  transcribed by `lfspk.probe.models.load_parakeet("m1")` through W0's
  `asr.transcribe` with the same chunking. It is written under
  `runs/W0/frontend/B-m1/<set>/` with an identity naming the weights and the
  m1 SHA-256. Every m1 claim is relative to B_m1; `asr.py` is not changed.
  The m1 path is implemented after `base` and is used only if W5 asks for it.
  `transcribe_masked`'s constants check may refuse m1 if its preprocessor
  buffers differ from the pinned ones; in that case W5 decides.
- `single` batching exists only for W5's optional replay. Batch size is 1,
  `compared_with` is set to the batched cache's identity hash, and the
  directory is separate (`replay/`).
- theta_b (design-r1 #2): the stage B identity's configuration must equal
  `fe.config(name).to_dict()` of the current front end. For C1 and C2,
  `fe.config` returns theta_b = None by design, and that is what is stored.
  For C3 and C4, the configuration's theta_b must also equal stage A's
  `identity()["theta_b"]` numerically. A missing or different value is
  refused.

**fe-5 Load-time checks.** These run on every load (metrics, select, report,
apply). Any failure refuses the whole cache, with no partial use.
1. `cachepin.require_headline(identity)`: the `single` replay is refused.
2. The identity equals the one recomputed from the current stage A identity,
   configuration, current B `asr.meta.json`, current `hook_code_sha256()` and
   batching. A hook or B change therefore makes the cache stale.
3. Stage A is validated fresh against the CURRENT expected identity, not only
   for self-consistency (design-r1 #3). The front end is built from the
   recorded factory spec and args, and the stage A identity is recomputed
   from it: `fe.identity()`, the set id and hash, the condition, the protocol,
   threads = 1, and the current `fe_stage_a.py` hash. The recomputed identity
   must equal the stored IDENTITY.json, and its hash must equal the one in
   COMPLETE.json and in stage B's identity. In addition, the recorded thread
   count, `identity()["analyse_threads"]` and every thread count observed in
   COMPLETE.json must all be 1. A self-consistent A/B pair made at another
   thread count, or by older code, is therefore refused (test).
4. Coverage: stage B's keys equal the expected keys exactly, and its
   COMPLETE.json agrees.
5. Every bypass entry passes `cachepin.verify_bypass` against the current B
   records, B identity and the frozen hashes.
6. Every masked entry's audio hash equals the frozen hash, and its
   `mask_sha256` equals stage A's recorded hash for that key, so purged
   arrays still pin what was applied.
7. Where the arrays are present, the bypass flag is recomputed from `u` and
   must agree.
B* has no stage A, so it is loaded by its own branch (design-r1 #4), which
replaces checks 3, 5, 6 and 7:
- the identity's stage-A field must equal the hash of {"kind": "bstar"};
- the configuration must be C1 with theta_b = None;
- coverage must be every mixture of the set, keyed `mix:<id>` with no
  condition, since B* involves no profile;
- no entry may be a bypass entry;
- every entry's `mask_sha256` must equal the hash of the zero arrays
  (log_mask float16 [128, N // 160 + 1], u float32 [N // 160 + 1]) for that
  mixture's length;
- every entry's `audio_sha256` must equal the frozen set's hash for that
  mixture (check 6's audio half, kept for B*; design-r2 #3);
- checks 1, 2 and 4 apply unchanged.
Stage B reads each mixture's file bytes once, requires their SHA-256 to be the
frozen hash, and decodes exactly those bytes (`fe_stage_b.decode_verified`;
code2-r1 #2). It intentionally accepts only the frozen format, 16 kHz mono:
anything else is refused with that message, never resampled or downmixed as
`util.load_audio` would (code12-r2 #2).
Tests cover each refusal on fixtures: a stale B record, a changed B identity,
an altered copy, a wrong batching mode, a missing coverage key, a mask hash
mismatch, a hook-hash change, a stage A made at 2 threads (self-consistent
but not current), a C1 cache checked against a numeric theta_b (it must
load), and a B* cache through its own branch (it loads; a non-zero mask hash, a
bypass entry, or an entry with the right key and length but another audio
hash is refused).

**fe-6 Evaluation records.**
- References are recomputed exactly as `refs.mixture_record` builds them:
  `refs.placed_words` from the split's Corpus (forced alignments) for the
  target (min_inside 0) and each interferer, and the frame labels from the
  frozen set. Synthetic tests use mixture_record's pseudo-reference branch.
- Reference guard (design-r1 #1). Comparing a few token fields cannot prove
  the references equal: a reference word changed from "red" to "green" while
  B says "blue" leaves every such field unchanged. Two checks replace it.
  1. Source pin. The Corpus's forced-alignment file must have the SHA-256
     recorded in each row's `meta.index_hashes.alignment` at render time.
     `placed_words` reads only those alignments and the placements stored in
     the row, so the target and interferer reference words, texts and times
     are pinned to what the frozen set was rendered with.
  2. Full record. For every mixture, `refs.mixture_record(row, labels,
     target_active, B, corpus)`, the function that wrote `words.jsonl`, is
     re-run on the current B cache and Corpus. Its whole record must equal
     the `words.jsonl` record in canonical JSON: every token field including
     decision spans and timestamps, target_ref with its times, n_ref, dels,
     untimed_errors, n_interferer_ref, dropout, dry_target_wer and the
     pseudo-reference agreement.
  3. The references the metrics use are the ones mixture_record builds (the
     same `placed_words` calls). Their 3-decimal rounding must equal the
     record's target_ref, and each interferer reference count must equal
     n_interferer_ref.
  Any difference refuses the run. Drift tests: a Corpus reference word
  changed (the reviewer's red/green case), a timestamp changed in
  words.jsonl, a dropout flag changed, and an alignment-file hash mismatch.
- A system's hypothesis is `align.tokens_from_words` of its record's words.
  For a word filter, it is B's tokens whose decision-span mean is >= tau,
  using `evaluate`'s token means on `decision_span` with 80 ms widening.
- Dropout of a system follows the rule of `refs.mixture_record`: untimed
  (S + D) / N > 0.5 with B's `dry_target_wer` <= 0.1.

**fe-7 Metric definitions (`tmetrics`, one implementation shared with W5).**
Agreed with W5 on 2026-10-22. `tmetrics` owns the definitions and the
threshold search. W5's `evalwords` will import them and keep only stage-0
glue (W5's follow-up diff). Stage 0 has not run, so no reported number moves.
- Per mixture and system X, with `align(hyp, target_ref, timed=True)` and
  `attribute(hyp, target_ref, int_refs, labels)`, both W0's and unchanged:
  - correct_X = the reference indices with an exact match;
  - S and D by reference-word region;
  - I by token region;
  - n_int and n_other (attribution source interferer or other) by token
    region;
  - region = `align.word_region`: overlap iff at least half of the span's
    frames are label 3.
- Unreachable set U, from B only: reference words j for which B's whole
  hypothesis has no token with r_j's text that is `align.compatible` with r_j
  (0.5 s).
- Per-mixture count vector, per region (single, overlap): n_ref, correct,
  lost = |correct_B - correct_X|, gained = |correct_X - correct_B|,
  gained_u = |(correct_X - correct_B) & U|, S, D, I, n_int, n_int_B,
  n_other, n_other_B. Per mixture also dropout_X and dropout_B. "Lost" and
  "gained" are by reference-word identity (W5 9.2), so a repeated word whose
  match moves counts as one loss and one gain (test: ref "red red", B "blue
  red").
- Statistics are ratios of weighted sums over mixtures, for each group and
  region (all, single, overlap):
  - R = n_int / n_int_B;
  - L+ = lost / N; G = gained / N; G_u = gained_u / N; net L = L+ - G;
  - E = (S + D) / N; WER = (S + D + I) / N; dWER = WER_X - WER_B;
  - other per N, and its change against B;
  - coverage = correct / N;
  - dropout share before and after.
  - R is undefined (NaN, counted as an invalid resample) when n_int_B = 0.
- dWER_S0 is dWER on group S0, all regions, in fraction units. The
  non-inferiority margin is +0.10 points = +0.001.
- The tau search for word filters (fe-9) lives in tmetrics too, so W5's
  stage 0 and the harness share it.
- Hand-computed fixtures test every statistic, including region splits, and
  a check that L+, G and E agree with W5's `evalwords` values on the same
  fixtures, so that both users share the code rather than copies.

**fe-8 Bootstrap.**
- Joint speaker bootstrap exactly as `compute_metrics`:
  - universe = the involved speakers (`evaluate.involved_speakers`) of all
    rows of the evaluated half, sorted as integers;
  - `rng = default_rng(0)`, and per resample `bincount(rng.integers(0, U,
    U))`, B = 2000;
  - mixture weight = `weights_from_counts(involvement_matrix, counts)` times
    the headline mask.
- Every system and every paired difference is computed from the same weight
  vector of each resample. Paired differences, e.g. R_F - R_W, are differences
  of ratios within a resample.
- Percentile CIs come from `metrics.percentile_ci`: 95 % by default, 98.75 %
  for the confirmatory family. Valid-resample counts (`n_valid`) are reported
  per statistic.
- Every quantity fitted on half A is held fixed in every half-B resample: F's
  configuration, each W and its tau, the stacked tau. Half-B CIs are
  therefore conditional on the half-A choices and on the fixed contamination
  streams, as in NOTES.
- A test compares draws with `compute_metrics`' (same weights for the same
  rows).
- Contract on callers (tmetrics review r1): shared resamples require the same
  universe and the same row order as `compute_metrics`. The evaluator
  therefore asserts two things before drawing. The universe must equal
  `sorted({involved speakers of the half's rows}, key=int)`. The rows must be
  the manifest's rows of the half, in manifest order. A violation raises, and
  it is tested.

**fe-9 Word-filter thresholds (exact, re-aligned, no monotonicity
assumed).**
- For candidate W at the headline condition on half A, the kept set of
  mixture m changes only at m's own token means. Let ℓ_1 < ... < ℓ_K be
  those means. At each state s = 0..K (s = the number of m's levels below
  tau; s = K removes every token), the kept hypothesis is re-aligned and
  counted (fe-7).
- The candidate thresholds are every distinct token mean of the half-A
  headline mixtures, plus +inf (removes everything). This is the rule of W5's
  `evalwords.search_tau` / `largest_feasible` at faafdfd (W5 implI2-r1 #1),
  which moves into tmetrics as the single implementation, with that commit's
  results as the test reference. The convention is the decision rule's: a
  token is kept iff mean >= tau. So tau = +inf removes everything, and
  keep-everything is tau = the minimum token mean (any tau at or below it).
  That is the candidate with the smallest index, and it is always attainable
  (L+ = 0, dWER = 0).
- The pooled statistic at every candidate is the sum of per-mixture step
  functions. Difference arrays give an exact O(total levels) evaluation.
- Rules:
  - Equal budget: the largest candidate whose pooled S0-S4 L+ (vs B) is at
    most 0.5 % (lost <= 0.005 N + 1e-9).
  - Matched S0: the largest candidate whose dWER_S0 is at most F's half-A
    point dWER_S0.
  - If F's dWER_S0 lies below every candidate's, i.e. F's dWER_S0 is
    negative and no threshold, keep-everything (0) included, reaches it (W5
    9.3), the pairing is "infeasible" and H1b is "not tested".
  - The search scans all candidates; nothing assumes L+ or dWER_S0 to be
    monotone in tau.
- Tests: brute force on random fixtures (re-aligning at every threshold
  versus the step-function result); the repeated-word case (W5's fixture:
  ref "red red" at 0.0-0.3 / 0.5-0.8 against B "blue" 0.0-0.1 and "red"
  0.2-0.4, where removing "blue" moves the match from ref 2 to ref 1, so
  L+ = G = 0.5 with no matched token removed); the infeasible matched-S0
  case; and equality with faafdfd's `search_tau`. W0's fixed-alignment "target removed" at the same tau is
  reported beside L+.

**fe-10 Selection on half A (`select --half A`, dev only).**
- F among C1-C4 of the named checkpoint, by W5 9.3's rule:
  - eligible = the upper end of the paired 95 % CI of dWER_S0 (F - B) is
    below +0.001, and the pooled S0-S4 L+ point estimate is at most 0.005;
  - the reference is the eligible configuration with the lowest pooled S1-S4
    R;
  - the selected configuration is the first eligible one in the order C4,
    C3, C2, C1 whose 95 % CI upper end of (R - R_ref) is below +0.02;
  - with none eligible, the result is "F fails the guardrail" and there is no
    pairing.
  - The harness implements this rule (agreed with W5, who reviews it
    against W5 9.3) on the bootstrap draws of fe-8.
- For each candidate W: its two thresholds (fe-9), then per pairing the
  candidate with the lowest half-A pooled S1-S4 R at its threshold. Ties go
  to the first in the fixed candidate list.
- Confirmatory binding (design-r1 #5, r2 #1). W5 9.3 pre-registers F as
  C1-C4 of R1 seed 0.
  - **The registration.** `lfspk/extract/RESULTS.md`, section
    "Pre-registered confirmatory checkpoint" (W5 82e4a4c), holds the entry.
    The file must contain exactly one line matching
    `^\s*confirmatory-checkpoint: R1-s0 sha256=([0-9a-f]{64})$`. The
    placeholder (`sha256=<to be recorded after training>`) is not a
    registration, and zero or several matches are refused.
    - It is read from the committed blob at HEAD, and the working-tree file
      must equal that blob, so an uncommitted edit is refused.
    - The registration event is an explicit anchor commit, not a text search
      (design-r3 #1; `git log -S` cannot identify it reliably across drafts,
      reintroductions or merges). W5 makes one dedicated commit whose message
      contains the fixed tag `REGISTER confirmatory-checkpoint R1-s0 <sha>`
      (the 64-hex SHA-256). The evaluator finds it with
      `git log --fixed-strings --grep='REGISTER confirmatory-checkpoint R1-s0 '`
      over HEAD's history and requires all of the following:
      - exactly one such commit, an ancestor of HEAD, with a single parent;
      - the tag's SHA equal to the line's SHA;
      - against its parent, the commit's diff of `lfspk/extract/RESULTS.md`
        is exactly one removed line and one added line: the placeholder
        `    confirmatory-checkpoint: R1-s0 sha256=<to be recorded after
        training>` becomes the valid line, with no other change to that
        file;
      - the commit's post-image of the file contains the unique valid line,
        equal to HEAD's line.
      Zero or several anchors, a diff of any other shape, or a HEAD line
      that differs from the anchor's means refusal.
    - Its registration identity is {the SHA-256, the anchor commit, the
      file's blob hash at the anchor}. Rewriting history (a rebase) changes
      the commit id and so invalidates every artefact that recorded the old
      one. That is accepted: such artefacts are refused and must be
      regenerated.
  - **Supersession (2026-10-23, AJ's decision for R1-s0).** A registered
    checkpoint can be replaced before it is evaluated. The anchors then form
    one strictly ordered chain of dedicated single-parent commits in HEAD's
    history, alternating REGISTER, SUPERSEDE, REGISTER, ...
    - A SUPERSEDE commit's message contains
      `SUPERSEDE confirmatory-checkpoint R1-s0 <old>`, naming the SHA the
      preceding REGISTER registered.
    - Its diff of `lfspk/extract/RESULTS.md` removes exactly that valid line
      and adds exactly two lines: the placeholder, and
      `    superseded-checkpoint: R1-s0 sha256=<old>`.
    - It is valid only if the run ledger holds no stage-B event, started or
      complete, of `<old>` from a run that began before the SUPERSEDE commit.
      That is stricter than "no complete stage B", because a started stage B
      may already have written transcripts. Select and report consume only
      complete stage B, so no metric of `<old>` can exist either. The smoke
      refuses R1 seed 0.
    - "Before" means that the run's recorded evaluation HEAD is not a
      descendant of the SUPERSEDE anchor. A complete event is judged by its
      start's HEAD, paired by run id. A complete without its start, or a run
      without a HEAD, counts as before (conservative).
    - Later exploratory runs of the superseded checkpoint therefore never
      invalidate the supersession (sup-r1 #1).
    - Every registration lookup (stage A/B preflight and load, smoke,
      `confirmatory_evidence`) uses the ledger the evaluator writes to
      (sup-r1 #3).
    - Between SUPERSEDE and the next REGISTER nothing is registered, so dev
      runs need `--exploratory`.
    - The next REGISTER is the unchanged REGISTER rule, and it may not
      register a superseded SHA again.
    - At HEAD, the file holds exactly what the chain implies: one valid line
      or the placeholder, and one superseded line per SUPERSEDE. Every line
      mentioning either keyword counts, malformed ones included (sup-r1 #4).
    - Each REGISTER's post-image holds exactly its one valid line, as in the
      single-registration rule (sup-r1 #2).
    - The registration identity adds
      `superseded: [{sha256, register, supersede}]`. It is unchanged when
      nothing was superseded.
    - A superseded checkpoint can only ever be exploratory: its SHA differs
      from the registered one, so no artefact of it is confirmatory-eligible.
    - It never blocks the new checkpoint, because `confirmatory_evidence`
      counts only ledger runs of the registered SHA.
    - The superseded checkpoint's incomplete ledger events stay (the ledger is
      append-only), and the supersession note cites them. Its stage-A outputs
      on dev are quarantined (R1-s0:
      `runs/W5/masks_quarantine_R1-s0_20261023/QUARANTINE.json`).
  - **Enforced at evaluation time, not only at select.** Stage A and stage B
    on any dev set (dev-v1, noise-dev-v1, and B* too) read the registration
    before doing anything.
    - With a valid registration, the registration identity is written into
      the stage-A/B identity, together with `confirmatory_eligible`. That
      flag is true iff the front end's `identity()` says run "R1" and seed 0,
      its checkpoint SHA-256 equals the registered one, and `--exploratory`
      was not given.
    - Without a valid registration, they refuse unless `--exploratory` is
      given. An exploratory artefact records registration = null and
      `confirmatory_eligible: false`, and can never feed a confirmatory
      selection.
  - **Run binding.** Every dev stage A/B run records a run event in its
    identity: a random run id, the UTC start time, the anchor commit (or
    null), and the evaluation HEAD (`git rev-parse HEAD`, plus whether the
    tracked tree was clean). It also appends the same event, with the
    checkpoint SHA-256, set, stage and exploratory flag, as one line to the run
    ledger `runs/W0/frontend/LEDGER.jsonl`.
  - **At select.** A selection is `confirmatory` only if every dev artefact it
    consumes (stage A, every stage B configuration, B*) carries the same
    registration identity, which must also be the current one, and is
    confirmatory-eligible.
    - It is also refused if the ledger shows a dev run of the registered
      checkpoint whose evaluation HEAD is not a descendant of the anchor, or
      that lacks the registration.
    - The registration identity, the run events of the consumed artefacts and
      the ledger file's SHA-256 go into the selection's evidence. The
      orchestrator commits the ledger hash to RESULTS.
  - **What this does and does not guarantee (design-r3 #2).** The anchor, the
    per-artefact run binding and the ledger catch accidental out-of-order runs
    in this checkout: an artefact made before the registration cannot be used
    in a confirmatory selection, and an earlier ledger entry blocks it. They do
    not prove that no dev evaluation happened earlier. A deleted or edited
    ledger, another checkout, or another machine would go undetected. That
    case is covered by procedure, not by code: no W5 checkpoint is evaluated
    on dev before its registration except with `--exploratory`, and the
    orchestrator audits this.
  - Every other checkpoint (R1 seeds 1-2, R2, R3, R4, any retrain), and any
    exploratory artefact, gets `confirmatory: false`. Its reports carry the
    family's numbers only under "exploratory" headings, with 95 % CIs and no
    supported/not-resolved verdicts.
  - Tests:
    - the placeholder is refused;
    - two matches are refused;
    - an uncommitted edit is refused;
    - an artefact without the registration cannot be confirmatory;
    - a ledger entry that predates the registration blocks confirmatory;
    - a non-R1-s0 checkpoint is exploratory.
- The artefact `selection.json` has two parts (design-r1 #7).
  - `transfer`: what is carried to another set, and nothing set-specific.
    - The front end's factory spec and args, `fe.identity()` and its hash
      (checkpoint SHA-256, theta_b, code).
    - The selected configuration's `InferenceConfig.to_dict()`.
    - The weights (`base` | `m1`).
    - For each pairing, W's scorer spec and sorted args (the
      `scorer_identity` fields without set id and hash) and its tau.
    - The stacked tau.
    - The `confirmatory` flag and its evidence.
    - Code identity (design-r2 #2, r3 #3): the hash of the accounting
      dependency closure. A fresh interpreter imports
      `lfspk.harness.tmetrics` and `lfspk.harness.frontend_eval`, as W5's
      `train.w3_modules` does for its W3 dependency, and the closure is every
      `lfspk` module (`lfspk` and `lfspk.*`, any package) in `sys.modules`
      afterwards (design-r4: `lfspk/api.py` supplies FRAME_SAMPLES,
      SAMPLE_RATE and frame_count to align and metrics, and `lfspk/paths.py`
      the data roots). Its hash is the SHA-256 over the sorted (path
      relative to the repository, file SHA-256) pairs. It covers tmetrics,
      align, refs, metrics, evaluate, the evaluator itself, api, paths, and
      any W5 modules imported at top level. W5's code is also covered by
      `fe.identity()` and `hook_code_sha256()`.
      - `report` and `apply` recompute it and refuse a mismatch, so an edit
        to any metric or accounting code after selection cannot pass
        unnoticed.
      - The evaluator imports its accounting dependencies at module top
        level, never lazily.
      - Tests: the closure contains tmetrics, align, refs, metrics,
        evaluate, `lfspk/api.py` and `lfspk/paths.py`. In a temporary copy
        of the repository, editing a dependency outside `lfspk/harness`
        (a comment added to `lfspk/api.py`) changes the closure hash, and
        `report` refuses the selection made before the edit. The git hash is
      recorded, but it is not what the check relies on.
  - `provenance`: where it was fitted.
    - The source set id and hash, half A, and the B identity.
    - The stage A and stage B identity hashes, and the score identities.
    - Content digests of everything read (design-r1 #6): the SHA-256 over
      the sorted keys and `cachepin.record_digest` of every B record used;
      the SHA-256 of the canonical JSON of every `words.jsonl` record used;
      the same digest over every stage B entry used; and the SHA-256 of
      every score file read.
  - Plus the git hash and a content hash as in `calibration.json`.
  - It is written only from dev half A.

**fe-11 Report (`report --half B --selection ...`; `apply` on other sets).**
- Every number is computed with the selection held fixed, and the artefact
  must come from dev half A.
- On the source set (half B of the same dev set), the `provenance` digests
  are recomputed and must match. A B cache or words.jsonl rebuilt under
  unchanged metadata is then refused, with or without bypass entries.
- On another set (noise-dev-v1, or the sealed sets under `apply`), provenance
  is reported but not matched, since set hashes and caches differ by
  construction. The destination's own caches pass fe-5 and fe-6
  independently. The destination stage A/B must have been made by the same
  `transfer` front-end identity and configuration, and the destination word
  filters' score directories must carry the same scorer spec and args. The
  taus are applied unchanged.
- Every report records the content digests of its own inputs, in the same
  form.
- Tables per group (S0-S4, pooled S1-S4, pooled S1-S4 without B-dropout
  mixtures, pooled all) and region:
  - R, L+, G, G_u, net L, E, WER, other and dropout, for F, each pairing's W,
    B* and B, with paired 95 % CIs of F - B and F - W;
  - bypass rate per scenario;
  - the share of masked transcripts identical to B's;
  - B* - B (transcripts identical, dWER per scenario) as a diagnostic.
- The confirmatory family is reported on half B only, each with 98.75 %
  percentile CIs:
  - H1a: CI of R_F - R_Weq (pooled S1-S4) entirely below 0.
  - H1b: the same for W_matched, or "not tested (infeasible)"; the family
    size stays 4.
  - H2: CI of G_u - L+ for F (pooled S1-S4) entirely above 0. E_F - E_B is
    shown beside it as descriptive only.
  - H5: CI upper end of dWER_S0 (F - B) below +0.001.
  - Each claim is "supported" or "not resolved". Everything else is labelled
    exploratory (95 %).
- Other conditions report F against B only, at the selected configuration
  (W5 9.6), with no pairing. The secondary groupings (relation, same_chapter,
  mixed RIR) are point estimates.
- `apply` (orchestrator only, sealed sets): the same report with every
  quantity from the dev half-A artefact and no half restriction.

**fe-12 Stacking (optional, exploratory H8).**
- The equal-budget pairing's W is applied to F's transcript. Its saved frame
  scores of the original audio are averaged over the decision spans of F's
  tokens.
- tau is the largest threshold, by the fe-9 machinery on F's token means,
  whose pooled S0-S4 L+ of F+W relative to B is at most 0.5 % on half A.
- No shortcut (design-r1 #8). Even when F alone exceeds the budget, every
  attainable threshold is scanned: under re-alignment, filtering F's
  transcript can lower L+. For example, with ref "red red", B "red" and F
  "blue red", removing "blue" takes L+ from 50 % to 0 %. Stacking is
  infeasible only if `search_tau` finds no candidate within the budget (test).

**fe-13 noise-dev-v1 (W5 9.4).**
- The same stages. Groups are family (noise, music) x SNR (20, 10, 5, 0), per
  family pooled, and all pooled.
- There are no interferers, so R is undefined. Reported per band: WER, E, L+,
  G, dWER against B with paired CIs, and the bypass rate.
- F's configuration comes from the dev-v1 half-A selection artefact (apply
  mode). H6 uses half-B speakers. F at C1 and other fixed checkpoints may use
  all speakers.
- Prerequisite, delivered by the noise-set owner (W0, confirmed
  2026-10-22): a complete `data/harness/asr/noise-dev-v1/asr.jsonl` (keys
  `mix:<id>` and `tdry:<id>`), `asr.meta.json` equal to dev-v1's B identity,
  and `words.jsonl` from `refs.build`. The evaluator refuses to run without
  them, and fe-5/fe-6 apply to them unchanged.

**fe-14 CPU latency (W5 10.6).**
- Run in a subprocess with `evaluate.CPU_ENV`, using `_verify_threads` before
  and after, on `evaluate.latency`'s 30 fixed dev mixtures, with the profile
  from the first 3 builtin clean dictations.
- Measured: `analyse` + `apply` (C1, and the selected configuration) per
  audio second, median and p90, plus `update` per 10 s dictation.
- Beside it, under the same environment and mixtures, Parakeet `base`'s
  preprocessor and encoder forward on CPU (FP32, batch 1), measured the same
  way. This requires `./python-nemo`.

**fe-15 Scorer-path invariance.**
- No edit to the scorer path.
- `tests/test_W0_scorer_regression.py` pins:
  1. a SHA-256 digest of `compute_metrics` output on the synthetic fixture of
     `test_W0_evaluate` (canonical JSON), recorded at the commit before this
     work;
  2. dev-v1's and test-v1's `HASH` values against NOTES, and SHA-256 of
     `CONTENT.sha256` equal to `HASH`. Skipped without the data mount; it
     reads the listings, never the audio.
  3. a full stage A/B/report run on a synthetic set whose directory is
     read-only, with its content hash unchanged afterwards.
- After the review closes, a CPU job re-runs `evaluate metrics` for the
  oracle on dev-v1 and checks that `results.json` is unchanged except for
  timing fields.

**fe-16 Cost and jobs.**
- Stage A: about 5110 x 12 s of audio per condition, at the front end's CPU
  rate. 8 workers with 1 thread each; `--mem` is set from a smoke.
- Stage B: per configuration, at most 5110 transcriptions. Mostly fewer:
  bypassed items are copied.
- With C1-C4 plus B*, about 5 x B's mixture pass. B's full worklist took
  about 25 min on the shared GPU, so this is about 1-2 h. VRAM is measured in
  the smoke and leased honestly.
- Each non-headline condition runs stage A (CPU job), then stage B (GPU job,
  `after`), then purge.
- Metrics: the re-alignment of every system's hypotheses is CPU only (about
  0.2 ms per alignment, measured on dev-v1 words), well under an hour.

**fe-17 Limits (stated, not fixed).** Batch-context effects on masked items
are a harness artefact. They are not quantified, except by W5's optional
replay (W5 10.2). Half-B CIs are conditional on the half-A choices. Re-aligned
L+ and G can move between repeated words; they are counts of identity
changes, not of acoustic losses.

### 14.3 Handoff for the agent building `evaluate frontend`

Agreed split (orchestrator, W5 at f4762c9): W5 supplies the factory
(`MODULE:CALLABLE(**str kwargs) -> FeatureFrontEnd`; concrete one
`lfspk.extract.harness_frontend:make`), `identity()` (stage-A key),
`InferenceConfig`, `frontend.apply` / `frontend.bypassed` (True exactly when
apply returns None), `nemo_hook.MaskedPreprocessor.install(model)` +
`set_batch(audios, mask_outputs, config)` (content-hash matching; returns
bypass flags; unregistered rows raise KeyError) + `hook_code_sha256()`, and
`cachepin` (`record_digest`, `pin_bypass`, `verify_bypass` / `StaleCache`,
`frontend_cache_identity`, `require_headline`). W0 builds stages A and B, the
pin re-check on every load, the metrics, the bootstrap, the word-filter search
and the latency. Read W5's `lfspk/extract/api.py` docstring (steps 1-5) and
W5 DESIGN 9-10 (normative, contract 7c7c1fa).

Superseded at f2638ba (W5 implI1-r1): `set_batch` and content matching were
replaced by `nemo_hook.transcribe_masked(model, audios, mask_outputs, config,
batch_size)`, which returns W0 records (None for bypassed items) in the
caller's order, declares positional rows per batch, verifies each row's length
and sample hash, and checks the model's front-end constants first. 14.2 uses
it.

Reuse, do not re-implement:
- Enrollment protocol and condition keys: `evaluate._score_speaker` /
  `cond_key` / `expected_score_keys` (copy the loop; the contaminated-prefix
  reuse is exact and reviewed). Score-directory pattern:
  `prepare_score_dir`, `scorer_identity`, `check_score_identity`, COMPLETE.
- ASR job: `lfspk/harness/asr.py` (`load_model`, `transcribe`,
  length-sorted chunks, `check_resume` identity + per-entry audio SHA-256,
  `read_jsonl` / `truncate_incomplete_tail`). B is
  `data/harness/asr/<set>/asr.jsonl` keys `mix:<id>`; its identity is
  `asr.meta.json` (= `asr.cache_identity()`).
- Word records: `refs.mixture_record(row, labels, target_active, asr, corpus)`
  with `asr["mix:<id>"]` replaced by the system's record; `tdry:` and `idry:`
  come from B's cache. It gives tokens (decision frames, attribution, target op,
  regions), `target_ref`, dels, dropout.
- Re-aligned accounting: `align.align(hyp, ref, timed=True)` (three-key
  lexicographic cost, 0.5 s tolerance; `compatible` for G_u's unreachable
  test), `error_counts`, `evaluate.realigned_wer` as a model.
- Bootstrap: `metrics.involvement_matrix` / `weights_from_counts` with
  `evaluate.involved_speakers`, seed 0, B = 2000; `percentile_ci`, `n_valid`.
  Per-reference-word correctness (for L+, G, G_u) is per mixture, so build a
  per-mixture count matrix (like `metrics.Ledger.static`) and every statistic
  is a weighted sum; paired differences come from the same weights.
- Word filters: `Ledger` for a filter's own tokens; for re-aligned L+ at a
  tau, re-align the kept tokens (`realigned_wer`), searching tau over the sorted
  unique token means (L+ is monotone in tau only approximately under
  re-alignment, so search all levels or verify the chosen one).
- Latency: `evaluate.CPU_ENV`, `_verify_threads`, the latency subprocess.
- Dev halves: `halves.dev_halves()`; rows carry `half`.

Gotchas:
- Frozen sets and B are read-only; never write into `data/harness/sets/`.
  `content_hash(root)` is read-only by default.
- Calibrate or select only on dev (split check as in `compute_metrics`); the
  sealed test sets (test-v1, noise-test-v1) are evaluated only by the
  orchestrator, with half-A/dev quantities fixed.
- `metrics.SCENARIOS` lacks "N": the noise set needs its own grouping (family x
  SNR) and has no interferers (R undefined; report WER, E, L+, G).
- Mixture length N = 160 F samples; Parakeet frames are F + 1; NeMo raises for
  inputs under 2 frames.
- Bypassed mixtures must use B's record copied and pinned, never a
  re-transcription; refuse a stale cache on load.
- TMPDIR is on the HDD: synthetic test fixtures go to /tmp
  (`synthetic.SyntheticCorpus`); keep tests under a minute.
- A full scorer evaluation takes ~45 min; frame statistics only at the
  headline condition.
