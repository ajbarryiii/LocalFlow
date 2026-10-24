# W0 benchmark harness: results and review log

Status: in progress (2026-10-21). Numbers appear here only after the stage they
belong to has passed its sol-loop review.

## Sol-loop log

### Stage `mix` (design + mixing API)

**r1** (commit ac1ba79, gpt-6.1-sol xhigh, run by the orchestrator): 11
findings, 2 high, 8 medium, 1 low. All accepted; fixes in the r2 diff.

| # | sev | finding | response |
|---|---|---|---|
| 1 | high | activity floor ignored digital silence; a burst padded with zeros had no active frames | floor percentile now over all frames (zeros at -120 dB) and threshold capped at L_hi - 15 dB; regression tests for both cases |
| 2 | high | RIR provenance cue: target always own-bank, interferers often measured or other-room | primary mode `coherent`: every source in the target's bank room (distinct far roles, laptop-speaker role for calls, events in the same room); secondary mode `mixed`: every source including the target draws bank-other-room / OpenSLR 26 / measured with p 1/3 each (measured near field = REVERB 0.5 m); reported separately, tau from primary only; test asserts pools and rooms |
| 3 | med | stale LibriSpeech index accepted after the dev split grew | index records `subsets`; `Corpus` refuses a mismatch; JSON and hash caches keyed by mtime and size; test |
| 4 | med | reported SNR excluded event and self-noise; events set relative to the target | SNR now on acoustic noise (ambience + event scaled jointly; event U[0, 10] dB over ambience on its span); `snr_total_db` reports target over all noise including self-noise; tests check both |
| 5 | med | pairing broken by retries (reseeded base) and per-variant limiter gain | base stream independent of scenario and attempt; `render_paired` applies one limiter gain to all variants; frozen sets render S0-S4 of a target as one group, enrollment twins as a pair; bit-exact tests |
| 6 | med | index hashes did not pin source audio, bank NPZs, CHAPTERS.TXT | `pin_sources`: meta.sources maps every file read to its SHA-256 (frozen sets on); CHAPTERS.TXT hash in index_hashes; test |
| 7 | med | TV metadata listed programme speakers not audible after the crop | only utterances with active frames inside the crop are listed; speakers derived from them; test |
| 8 | med | omitting contaminators from the bootstrap was argued, not justified | estimand changed explicitly: CIs conditional on the fixed contamination streams (DESIGN 8, NOTES); dev contaminators drawn from the other dev half, so never an evaluation interferer of the same half |
| 9 | med | LibriVox projects shared across splits | policy (orchestrator): not held out, as in LibriSpeech; documented; secondary report on dev targets whose test project never appears in train (`test_project_in_train`) |
| 10 | med | DEMAND split by time, not environment | whole environments per split by stable-hash ranking (test OHALLWAY, dev OOFFICE, train the other four) |
| 11 | low | `enrollment()` dictations lacked their relation | `enrollment_streams` attaches relation and index to every dictation; test |

Also from r1's closing remarks: per-relation budget check at the pooled tau is
in the evaluator (`by_relation`).

Contract/scope changes folded in during r1 (orchestrator): dev = dev-clean +
dev-other (73 speakers); canonical dev halves stratified by subset, sex and
session class; mixtures never cross halves.

**r2** (fix diff ac1ba79..d8355d5): 3 findings, 1 high, 2 medium. All accepted.

| # | sev | finding | response |
|---|---|---|---|
| 1 | high | counting zeros in the floor let padding force it to -120 dB, so room tone 30 dB under speech was labelled speech | floor from non-zero frames only, digital silence inactive by definition; the L_hi - 15 dB cap still covers r1's padded-burst case; regression test with padding + room tone + speech |
| 2 | med | mixed mode: measured targets all REVERB, measured far sources mostly BUT: a recording-family cue | measured pool restricted to REVERB 2014 (near 0.5 m and far 2 m in the same rooms) for both roles; BUT, RWCP, AIR unused; headset-bank exception and REVERB's fixed 2 m disclosed; test |
| 3 | med | event level set against whole-track ambience, not ambience over its span | event levelled to the ambience's level over the span plus U[0, 10] dB |

Also (orchestrator): the synthetic tests took minutes because TMPDIR is on the
shared data disk; the synthetic corpus now lives in /tmp (LFSPK_FAST_TMP), and
tests/test_W0_mix runs in about 5 s. No test is gated.

**r3** (fix diff d8355d5..11b6177): 2 findings, 1 high, 1 medium. Both accepted.

| # | sev | finding | response |
|---|---|---|---|
| 1 | high | +-1 LSB dither or sub-LSB padding still dragged the floor to -90 dB and made room tone speech | floor bounded as in LocalFlow's silence gate: estimated only from frames >= -70 dBFS and clamped to [-70, -40] dBFS (the orchestrator proposed the clamp; a clamp alone still mislabels the reviewer's case, because theta then falls to L_hi - 35 = -55 dB under room tone at -50.5 dB, so frames below -70 dBFS are also excluded from the estimate); regressions for zeros, LSB dither and sub-LSB noise, each with room tone and speech, plus padded bursts and steady speech |
| 2 | med | the event test did not test local levelling | synthetic ambience is now non-stationary (0/-12/+6 dB steps); `Mixture.noise_parts` exposes ambience, event and self-noise; the test asserts the measured event-over-ambience difference on the event span |

**r4** (fix diff 11b6177..822104f): 3 findings, 2 high, 1 medium, all about the
energy labeller (loud room tone above the -40 dBFS clamp became speech; quiet
recordings lost soft onsets; sparse speech in long dither padding moved L_hi
into the padding). The reviewer also showed the 99.6 % agreement figure did not
prove the changed frames were corrections. Orchestrator decision: stop tuning
an energy threshold; labels come from word-level forced alignments.

Response (r5 diff): `lfspk/harness/forced.py`, CTC forced alignment of the
LibriSpeech transcripts with torchaudio's `forced_align` on wav2vec 2.0 base
960 h (MIT; the licence-less MFA alignments of CorentinJ were rejected).
Pre-registered label rule: merge inter-word gaps under 200 ms, pad 40 ms
(changed from a first proposal of 20 ms and no merging after a 40-utterance dev
smoke showed CTC peakiness; reasons and numbers in DESIGN.md section 5).
Fallback: Parakeet timestamps for utterances the aligner fails on, counted per
split. Every speech source is LibriSpeech now (us-gov dropped from S2). The
energy rule stays as a diagnostic only. An utterance without an alignment is a
render-time error.

Hand check on the dev smoke (5 utterances, word intervals beside Parakeet's):
CTC intervals are tight and well ordered, e.g. 84-121123-0001 "BUT[0.30-0.40]
IN[0.46-0.50] LESS[0.56-0.72] THAN[0.74-0.84] FIVE[0.92-1.10] ...", Parakeet
"But[0.16-0.32] in[0.40-0.56] less[0.56-0.72] than[0.72-0.96] five[0.96-1.12]";
words are never placed in silence (98-99 % of aligned frames are energy-active)
but ends are early and fluent speech shows CTC gaps, hence the merge and pad.

**r5** (final round, fix diff 822104f..ae1152e): 5 findings, 1 high, 4 medium.
Fixed after the round (no round 6; orchestrator decision):

| # | sev | finding | response |
|---|---|---|---|
| 1 | high | an empty Parakeet fallback was accepted as "no speech" | empty fallback output is recorded as a failure; empty alignments are treated as missing; render raises; test |
| 2 | med | forced.py imported the then-untracked asr.py | asr.py committed (24efbb7); tests run from a clean `git archive` export |
| 3 | med | float gap arithmetic merged some exactly-200 ms gaps | merge and padding computed in integer milliseconds; equality tests at five timeline positions |
| 4 | med | the merge rule's justification leaned on the rejected energy labeller and the rule can turn a genuine short target pause into overlap | justification rewritten on the independent Parakeet comparison and the pause literature (with the Campione-Veronis caveat); the overlap inflation is disclosed; frozen sets store no-merge sensitivity labels and the evaluator reports frame metrics under both; word-level metrics do not depend on frame labels except the oracle and word regions |
| 5 | med | a truncated final JSONL record broke resumption | an incomplete final line is dropped with a warning (and cut before appending); any other malformed line raises; test |

Also: every placed source records its placements (utterance, slice, offset) in
meta, so labels can be recomputed under any rule (`mix.relabel`); a test shows
the primary rule reproduces the rendered labels exactly.

mix-r5 fixes verified by the orchestrator at 949504f (tests pass from a clean
`git archive` export). **The mix stage is closed after 5 rounds**: 25 findings
in total (6 high, 17 medium, 2 low), all accepted; one decision (r4) replaced
the energy labeller by forced alignments.

### Stage `eval` (ASR cache, attribution, evaluator)

**r1** (files at d4078c5): 10 findings, 2 high, 8 medium. All accepted.

| # | sev | finding | response |
|---|---|---|---|
| 1 | high | 512-bin AUC/EER histograms collapsed saturated scores (0.9999 vs 0.999 gave AUC 1 with CI [0.5, 0.5]) | exact weighted rank statistics (FrameRanks, ported from W3) for the point estimate and the bootstrap; test with the reviewer's fixture |
| 2 | high | every set was its own calibration set, so a test evaluation would tune tau on test | `run` calibrates on dev and writes a hashed calibration.json; `apply` uses fixed dev taus, never re-fit (also in the bootstrap); calibrating on split=test raises; tests |
| 3 | med | EER taken at the nearest ROC point | interpolated at the FRR = FAR crossing; reviewer's example (0.5) as a test |
| 4 | med | degenerate calibration kept words the budget allowed removing | unconstrained budget (no candidates, or all removable) -> remove all; test |
| 5 | med | float arithmetic broke the >= 50 % inclusion of cut interferer words | integer milliseconds; exactly-half test |
| 6 | med | simultaneous duplicate words vanish from the interferer denominator | tokens exactly matched by target and interferer are flagged ambiguous; sensitivity metric counts them as interferer; count reported |
| 7 | med | dropout can make the primary metric look perfect | per-mixture dropout flag; interferer kept on non-dropout mixtures and target coverage reported beside the primary metric |
| 8 | med | "single-threaded CPU latency" not enforced | latency subprocess with CPU_ENV (no GPU, one thread for OMP/MKL/OpenBLAS/ORT), refused otherwise, verified torch threads recorded |
| 9 | med | resumed ASR caches had no input/config identity | cache identity (model hash, decoding, NeMo version) and per-entry audio SHA-256; mismatched resume refused; test |
| 10 | med | results.md omitted robustness families | report shows every computed family (single tau, relations, secondary groupings, no-merge frame metrics, EER, oracle, ambiguity, non-dropout, coverage, cross-fit, valid resamples); test |

**r2** (fix diff d4078c5..cb5de15): 5 findings, 1 high, 3 medium, 1 low. All accepted.

| # | sev | finding | response |
|---|---|---|---|
| 1 | high | `metrics --out <A's scores> --scorer B` exported a calibration labelled B | scores/IDENTITY.json (scorer, sorted args, set id and hash, hash); checked before metrics, export and apply; test |
| 2 | med | apply evaluated the oracle's calibration eagerly and fell back to it | the oracle tau must be in the artefact; missing is an error; test |
| 3 | med | non-dev (train) calibration accepted and labelled dev | calibration and export require split == dev; test with test and train |
| 4 | med | thread verification preceded scorer construction | verified after construction and after measurement (env and torch threads, CUDA visibility); test |
| 5 | low | ambiguity count missed ambiguous tokens the interferer won | counted from the flag directly; test |

Also (orchestrator): no-candidate conditions are uncalibrated (NaN, null in the
artefact, not evaluable under apply); all-within-budget keeps a finite tau just
above the highest candidate; never remove everything on test.

**r3** (fix diff cb5de15..7d22978): 4 findings, 1 high, 3 medium. All accepted.

| # | sev | finding | response |
|---|---|---|---|
| 1 | high | a populated score directory without IDENTITY.json could acquire a false identity | `prepare_score_dir` refuses archives without an identity and another configuration's identity; COMPLETE.json (identity hash, key count, key-list hash) written only after scoring finished and was verified; metrics, export and apply require it; tests |
| 2 | med | partial archives silently shrank the evaluation pool | expected (condition, mixture) coverage computed from the frozen set's enrollment streams; loaded keys must equal it exactly; test with the reviewer's dropped S4 mixture |
| 3 | med | a NaN tau in one cross-fit direction was applied as "remove nothing" | that direction is marked uncalibrated and not evaluable; test |
| 4 | med | READY verification rewrote the frozen hash files | `content_hash` is read-only unless the freeze step asks to write; test |

Also: every condition reports how many bootstrap draws were used; below 95 % the
report labels the CIs conditional on calibratable resamples.

**r4** (fix diff 7d22978..4af0b7d): 1 medium finding, in W3's parity-test
fixture (an empty enrollment manifest now fails the coverage guard); W3 owns that
fixture and is updating it; the guard stays. No finding in W0's code. **The
eval stage is closed after 4 rounds**: 20 findings (4 high, 14 medium, 2 low in
W0 code, plus one in W3's fixture), all accepted.

**Eval re-opened for r5 (orchestrator decision after the dev-v1 sanity checks).**
Two problems found on real data: (1) the strict oracle reached no ceiling
(tau 0) because 0.64 % of correct target words had Parakeet spans wholly in
labelled pauses; the contract's decision rule now widens every word's span by
80 ms (oracle ceilings at 0/50/200 ms reported as sensitivity); (2) the 0.2 s
alignment tolerance split correct words (S0 timed WER 3.89 % vs 3.07 % untimed);
now 0.5 s, with a lexicographic cost so that among minimum-edit alignments the
one with most exact matches wins. Frame statistics at the headline condition
only (evaluation time).

**r5** (final, diff 1643994..9ade4d0): 3 findings, 1 high, 1 medium, 1 low; fixed
after the round (no round 6; the orchestrator verifies):

| # | sev | finding | response |
|---|---|---|---|
| 1 | high | the oracle widening-sensitivity taus were fitted on the evaluated set in apply | each widening's dev tau is exported in calibration.json; apply uses only those and refuses if missing; test |
| 2 | med | 0.5 s tolerance let a repeated word pair the target reference with the interferer's later occurrence | third cost key: smallest summed start-time difference (integer ms, capped), with an ordering assertion; reviewer's repeated-word test; randomized check that WER counts equal plain Levenshtein |
| 3 | low | DESIGN attribution section still said 0.2 s and the old tie rule | updated |

**The eval stage is closed after 5 rounds.**
Post-final-round fixes verified by the orchestrator at 5f795f8: eval stage
closed (5 rounds, 28 findings in total: 5 high, 20 medium, 3 low, plus one in
W3's fixture; all accepted).

## Sanity checks on dev-v1 (HASH 6d5fd40a...; word records at 5f795f8)

Headline condition builtin / clean / k = 10, 2800 primary mixtures, 56 targets.
Commands: `./python -m lfspk.harness.sanity all --set dev-v1`,
`./python -m lfspk.harness.evaluate run --set dev-v1 --scorer oracle` (and the two
baseline factories); outputs under runs/W0/.

- C3 Parakeet on dry dev: dev-clean 1.76 %, dev-other 3.13 % WER (5567
  utterances). S0 on the same targets: clean 2.14 % (dry 1.92 %), other 4.33 %
  (dry 3.25 %). S0 time-constrained WER equals the untimed WER after the 0.5 s
  tolerance (2.14 / 4.33 %); with 0.2 s it was 0.8 points higher. In S1-S4 the
  timed WER exceeds the untimed one by 0.7-3.2 points (untimed alignment pairs
  interferer words with target words).
- C2 keep-everything: WER after = before in every scenario. C4: max SIR error
  1e-6 dB, SNR error 1e-4 dB.
- C5 labels vs Parakeet word spans: per-utterance recall 0.909 over all dev
  utterances (passes 0.9); pooled over S0 dry tracks 0.856 (fails). Parakeet
  spans run long; both stated.
- Interferer words transcribed by Parakeet (primary, 730 mixtures each):
  S1 0.77 per mixture (70 % of mixtures none), S2 2.2 (48 % none), S3 8.5,
  S4 2.5 (53 % none); headline totals S1 427, S2 1200, S3 4845, S4 1445.
- Target dropout (> half of target words lost, dry target clean): S0 0 %,
  S1 6.4 %, S2 15.9 %, S3 12.1 %, S4 18.1 %.
- C1 oracle (80 ms widening rule), tau 0.125: interferer words kept S1 56.7 %
  [38.9, 77.1], S2 37.4 % [28.4, 47.0], S3 1.4 % [0.8, 2.0], S4 48.9 %
  [40.8, 56.6], pooled S1-S4 18.5 % [14.8, 22.7] (13.4 % without dropout
  mixtures); every overlap word kept. Target words removed 0.48 % pooled, of
  which S0 1.08 % (S0 WER +1.08 points): the oracle spends most of its budget on
  clean speech whose Parakeet spans fall in labelled pauses. Sensitivity: at
  0 ms widening tau 0 and nothing removed (C1 fails without widening); 50 ms
  18.0 % kept; 200 ms 18.9 % kept, S0 +1.21.
- Energy gate: tau 0.125, keeps 96.7-99.3 % of interferer words, S0 WER +0.92;
  frame AUC 0.53-0.63. CPU latency 0.25 ms per audio second.
- Frame AUC of the oracle under the no-merge labels: 0.96-0.98 (S1, S2, S4),
  1.00 (S3), EER 3.7 % pooled: the merge rule's overlap inflation.
- Attribution with aligned true references agrees with the Parakeet
  pseudo-reference cross-check on 98-99.6 % of tokens.
- Property of the word rule, not of any scorer: even the oracle spends about two
  thirds of its 0.5 % budget on S0 words whose Parakeet spans fall in labelled
  pauses (S0 +1.08 points), so the S0 increase of a good scorer should be read
  against the oracle's.

### Stage `overlap` (oracle-overlap diagnostic)

r1 (0d13957): 1 high, 1 medium, 1 low, all fixed in e329ea7 (causes on the
widened decision span with a separate widening cross-tab; uncalibrated oracle
refused; every row's labels validated; end-to-end parity test with the
evaluator). r2: clean. **Closed at e329ea7 after 2 rounds.**

### Stage `noise` (noise-only twin sets)

r1 (4579851): 1 high (own limiter gain broke pairing with dev-v1's S0), 2
medium (legacy meta gained a null field; ambience text) -> 7038923. r2: 1 high
(the S0 ambience was rescaled; now only the added MUSAN source is scaled), 1
medium (per-variant re-draws broke source pairing across SNRs; now per family,
56724e7) -> 80bcc58. r3: 1 low (peak checked on a differently rounded array)
-> a93f88d, verified by the orchestrator. Deviation accepted: the source
image's level is measured after the device colouring, like the target image's.
**Closed after 3 rounds plus the verified post-final fix.**

### Stage `frontend` (W0F: front-end evaluator, DESIGN 14.2)

**tmetrics r1** (commit f6146d1, `lfspk/harness/tmetrics.py` and
`tests/test_W0_tmetrics.py` with 22 tests): clean. The reviewer confirmed
that:
- the definitions match W5 9.2-9.3;
- `pooled_steps` applies each transition at the first candidate strictly above
  its level, ties are kept, and +inf removes everything;
- the budget and matched rules use the correct tolerances;
- the bootstrap draws match `compute_metrics`.
One caveat is held as a contract: callers must pass the same integer-sorted
speaker universe and row order (asserted in the evaluator; DESIGN fe-8). The
reviewer's sizing estimate, an extrapolation and not a measurement: at most
114,269 distinct means on dev, about 96 s per word filter on full dev and
about 24 s on half A. **tmetrics is closed at f6146d1 after 1 round.**

Afterwards, at W5's request (a403449, 54bd5a4; tests only, no change to
tmetrics): the agreement tests compare against W5's evalwords values frozen
from the f6bea72 blob (`tests/fixtures/W0_tmetrics_evalwords_f6bea72.json`,
with the inputs' digest pinned and the generator beside it), so the check
stays independent after evalwords imports tmetrics. `test_W0_tmetrics` now
has 23 tests.

**design r1** (b8a23ff, 80bcc58..b8a23ff): 9 findings, 1 high, 6 medium and 2
low. All are accepted; the fixes are in DESIGN 14.2.

| # | sev | finding | response |
|---|---|---|---|
| 1 | high | fe-6's guard compared token fields only; a reference word changed red -> green with B "blue" passes and moves G, G_u, E | the forced-alignment file is pinned to each row's `meta.index_hashes.alignment`; the whole B word record is recomputed with `refs.mixture_record` and must equal words.jsonl in canonical JSON; the references used are checked against the record; drift tests |
| 2 | med | theta equality would reject C1/C2 (fe.config returns theta_b None by design) | the stage B config must equal `fe.config(name).to_dict()`; numeric equality with identity()["theta_b"] for C3/C4 only; test that C1 loads |
| 3 | med | stage A was checked only for self-consistency, so an old self-consistent pair made at another thread count would load | stage A is re-derived from the current front end and code (stage-A code in its own module), and recorded, analyse and observed thread counts must all be 1; test with a self-consistent 2-thread cache |
| 4 | med | B* has no stage A, so every B* load would be refused | a dedicated B* branch: bstar stage-A marker, C1 with theta None, full mixture coverage, no bypass entries, zero-mask hashes per length; tests |
| 5 | med | confirmatory labels were not bound to the pre-registered R1 seed-0 checkpoint | `confirmatory` only when the checkpoint is R1 seed 0 (from identity()) with the SHA-256 W5 pre-registered in a committed entry; everything else is exploratory, with no verdicts |
| 6 | med | the selection did not pin B's transcript contents (identity is metadata only; C1 has no bypass pins) | the selection's provenance records content digests of the B records, words.jsonl records, stage B entries and score files read; they are re-verified on the source set |
| 7 | med | cross-set application conflicts with matching input identities | the selection is split into `transfer` (front-end identity, config, weights, W specs and taus, stacked tau) and `provenance` (source-set digests); destination caches are validated independently by fe-5/fe-6 and must carry the transfer identities |
| 8 | low | the stacking shortcut assumed monotonicity (ref "red red", B "red", F "blue red": removing "blue" takes L+ from 50 % to 0 %) | infeasible only after scanning every threshold (`search_tau`); test |
| 9 | low | the noise-cache handoff was not stated as a prerequisite | fe-13 states it: complete asr.jsonl, asr.meta.json under B's identity, and words.jsonl, delivered by the noise-set owner; refused otherwise |

**design r2** (fix diff b8a23ff..51bc566): 3 medium findings, all accepted.
The reviewer confirmed the rest: the B* marker keeps B* separate from F at C1,
and validating stage A needs no mask recomputation.

| # | sev | finding | response |
|---|---|---|---|
| 1 | med | pre-registration timing was stated, not enforced: dev metrics could run first and a chosen SHA be committed later | stage A/B on any dev set require the committed registration (W5's one-line format in lfspk/extract/RESULTS.md, placeholder refused) or an explicit `--exploratory`; the registration identity (SHA, introducing commit, blob) is in every stage-A/B identity and the selection evidence; select requires the same registration on every consumed artefact; a run ledger blocks confirmatory if any dev run of the checkpoint predates the registration; tests |
| 2 | med | the transfer identity omitted tmetrics; the recorded git hash was never compared | the content hashes of tmetrics.py and frontend_eval.py are in `transfer`, recomputed and required equal by report and apply |
| 3 | med | the B* branch dropped the frozen-audio check | the per-entry frozen audio hash is checked for B*; refusal fixture with the right key and length but other audio |

**design r3** (fix diff 51bc566..425928b): 3 medium findings. The reviewer
confirmed that the B* audio fix is complete, that the eligibility rules
exclude exploratory artefacts, and that the placeholder is refused. Fixes
follow the orchestrator's decisions: deliberate circumvention is outside the
threat model; the mechanism stays simple and its limits are stated.

| # | sev | finding | response |
|---|---|---|---|
| 1 | med | `git log -S` does not reliably identify the registration event | an explicit anchor: one dedicated commit tagged `REGISTER confirmatory-checkpoint R1-s0 <sha>` (found with git log --grep), an ancestor of HEAD with a single parent, whose diff of lfspk/extract/RESULTS.md turns exactly the placeholder line into the valid line and nothing else, its post-image line equal to HEAD's; anything else is refused; a rebase invalidates prior evidence (stated) |
| 2 | med | a local ledger cannot prove that no earlier dev evaluation happened | the guarantee is narrowed and stated in plain words: accidental out-of-order runs in this checkout are caught; deliberate deletion and off-machine runs are covered by procedure and the orchestrator's audit; each artefact is bound to its run event, the anchor commit and the evaluation HEAD; the ledger's SHA-256 goes into the selection evidence |
| 3 | med | transfer hashes omitted accounting dependencies (align, refs, metrics helpers) | the hash of the lfspk.harness import closure of tmetrics and frontend_eval, found in a fresh interpreter as in W5's train.w3_modules; validated by report and apply; a test asserts the closure's contents |

**design r4** (fix diff 425928b..9704a68): one medium finding, accepted. The
reviewer confirmed that quoted tags refuse conservatively, the single-parent
rule applies to the anchor only, ancestry is `merge-base --is-ancestor`
(equality included), the narrowed guarantee is consistent, and the ordering is
deterministic.

| # | sev | finding | response |
|---|---|---|---|
| 1 | med | the accounting closure covered lfspk.harness only, missing lfspk/api.py (FRAME_SAMPLES, SAMPLE_RATE, frame_count) | the closure is every lfspk module imported (api.py and paths.py included); test: in a temporary repository copy, an edit to lfspk/api.py changes the hash and report refuses the earlier selection |

The r4 fix (9ef37f9) was verified by the orchestrator. **The front-end evaluator design is closed at 9ef37f9**: 4 rounds (16 findings: 1 high, 13 medium, 2 low; all accepted), plus a post-final fix verified by the orchestrator. The code stage follows in three review parts: (1) stage A, its loader, registration and ledger; (2) stage B and B*; (3) select, report, apply and the rest.

**code part 1 r1** (16b8586: stage A, its loader, the registration and the
ledger): 11 findings, 2 high, 7 medium and 2 low, all accepted.
- high: ledger start/complete events; a sanitised git environment.
- medium: hunk-line diff parsing; shallow clones refused; an fcntl lock for
  stage-A writers; live arrays counted and failed regenerations cleaned up;
  torch and an explicit one-thread declaration required, with refusal before
  COMPLETE; malformed registrations propagate under sealed apply; protocol
  parity with `_score_speaker` on recording stubs across all 12 conditions.
- low: only the exact placeholder means "unregistered"; the working tree is
  compared as bytes.

**code part 2 r1** (e5943ed: stage B and B*): 3 findings, 1 high and 2 medium,
all accepted: m1 refused until B_m1 exists; mixture bytes hashed, then the same
bytes decoded; retained bypass copies verified on resume.

**code parts 1-2 r2** (fix diff e5943ed..a8b6d17): 2 medium findings, both
accepted: `safe.directory` scoped per git call for foreign-owned checkouts
(test with git's own ownership simulation); `decode_verified` accepts only the
frozen 16 kHz mono format (refusal tests; DESIGN fe-5). The fixes at 9609294
were verified by the orchestrator. **Code parts 1-2 are closed at 9609294**:
part 1 in 2 rounds, part 2 in 1, the second round combined, plus a post-final
fix verified by the orchestrator.

**code part 3 r1** (066f28b: records, select, report, apply, latency): 7
findings, 1 high and 6 medium, all accepted. The reviewer confirmed the
hypothesis directions, pooling, the half-B masks, the matched-harm rule,
unmatched ledger starts, and F's pooled gross L+ requirement with no tau.

| # | sev | finding | response |
|---|---|---|---|
| 1 | high | W's scores could be substituted after selection: the report used any directory matching the scorer name and args | select requires each candidate's score files to cover the whole set (both halves) and pins them; on the source set the report consumes exactly the pinned files; conflicting duplicate scorer identities are refused; tests |
| 2 | med | the bootstrap count was not checked | select and report are confirmatory only at the registered B = 2000; any other count is exploratory, with the reason recorded; test |
| 3 | med | provenance was re-verified only for the selected configuration | the source-set report loads and re-verifies every configuration C1-C4 and every pinned word filter; test with a rebuilt non-selected entry |
| 4 | med | headline speakers whose streams do not reach k = 10 crashed the report | manifest row order kept, placeholders (B's hypothesis) for rows without the condition, masked out of every statistic as in W0's scorer path; digests list them as absent; the count is reported; test with a short-stream speaker |
| 5 | med | exploratory family intervals used 98.75 % | the level is passed in: 98.75 % confirmatory, 95 % exploratory; recorded and rendered; test |
| 6 | med | the latency CLI did not set up CPU_ENV | `latency` launches a fresh `latency-worker` interpreter with CPU_ENV before any measurement import; tested through that path |
| 7 | med | combined analyse + apply latency only for C1 | measured for every configuration, with the selected one highlighted; test |

Also in this fix commit, at the orchestrator's request:
- **The `smoke` subcommand**, in three steps so CPU work stays out of the GPU
  lease: `prepare` (CPU: a 20-mixture dev-v1 subset view plus stage A), `asr`
  (gpu:shared: stage B C1-C4 plus B* through the real transcribe_masked) and
  `metrics` (CPU: every load check, the reference guard, each configuration
  and B* against B).
- **Its safeguards.** Smokes are exploratory, live under `runs/W0/frontend/smoke/`
  and are refused by `select` and `report`. The default front end is a
  deterministic identity mask. A front end that is R1 seed 0, or whose SHA-256
  is the registered one, is refused outright.
- **Check on real data**: the dev-v1 subset construction (20 mixtures, 4 per
  scenario, both halves; hashes equal dev-v1's; verified decoding through the
  symlinks).

**code part 3 r2** (fix diff 066f28b..96705f3, smoke included): 2 findings, 1
high and 1 medium, both accepted. The reviewer confirmed that select and report
exclude placeholders correctly, that pinning the whole set feeds no half-B
scores into selection, that B* equality is diagnostic only, and that the
registered-SHA refusal also covers relabelled checkpoints.

| # | sev | finding | response |
|---|---|---|---|
| 1 | high | within one `--filter d1,d2` group, conflicting scores overwrote each other in directory order; reversing the order kept the path-to-SHA map and flipped W's R and H1a | any score key that appears in two files is refused; regression test with overlapping directories in both orders |
| 2 | med | smoke metrics hit a KeyError on rows the condition does not reach; guarding the lookup alone would let B placeholders into the sums | smoke masks those rows out of every F comparison as the main path does; the equality and bypass diagnostics use only rows with entries; test with a short-stream speaker |

12a9849 (smoke: B*-vs-B differences listed with per-mixture dWER) is part of
this fix diff.

**code part 3 r3** (fix diff 96705f3..f1c4c19, 12a9849 included): no
findings. The reviewer confirmed that the duplicate refusal is compatible with
W1's disjoint A/B directories and with W3's single --half all directory, and
that smoke masking and the B* diagnostics are correct. **Code part 3 is closed
at f1c4c19 after 3 rounds.** With the design (9ef37f9), tmetrics (f6146d1) and
parts 1-2 (9609294), the whole front-end evaluator is closed. Next: the smoke
jobs (queued behind the quiet host), then W5's stage-0 and R1-s0 outputs.

## Smoke on dev-v1 (accepted by the orchestrator)

`frontend_eval smoke --set dev-v1`, at f1c4c19, 2026-10-22. Run as three jobs:
w0f-smoke-prepare, w0f-smoke-asr (gpu:shared) and w0f-smoke-metrics. The set was
a 20-mixture dev-v1 subset (dev-v1-smoke: 4 per scenario, both halves) with the
identity-mask front end, all exploratory. Outputs are under
`runs/W0/frontend/smoke/identity-mask/`.

- **B* against B:** identical on 20 of 20 (no differing mixture, pooled dWER 0).
- **The mask path:** with the identity mask, F(C1-C4) through the real
  `transcribe_masked` hook equals B* on every masked item. L+, G and dWER are 0
  everywhere, and R is 1.
- **Bypass:** C3 and C4 bypassed 9 of 20, and every pin was verified on load.
- **Batching:** no batching sensitivity is visible at this size.
- **VRAM:** the peak was 6.48 GB (6.04 GiB), just over the 6 GiB lease. The
  memory-fraction cap bounds only torch's allocator, not the CUDA context or
  NeMo, so full dev stage B leases 8G (gpu:shared).
- **Known costs:**
  - NeMo's full CUDA-graph compilation fails ("invalid argument") and decoding
    falls back to native PyTorch CUDA graphs. It is slower, but transcripts
    are unaffected (B* = B).
  - Model restore took about 15 of the asr job's 18 min under host I/O and
    memory pressure, a fixed cost per stage-B job.
  - The job supervisor records mem_peak as null for these jobs, so RAM was not
    measured.

## Oracle-overlap diagnostic on dev-v1 (headline, oracle tau 0.125; e329ea7)

Interferer words kept by the oracle: S1 242/427 (56.7 %), S2 449/1200 (37.4 %),
S3 69/4845 (1.4 %), S4 706/1445 (48.9 %), pooled S1-S4 1466/7917 (18.5 %).
Share of kept words with more than half of their widened span covered by target
speech: S1 82.6 %, S2 77.1 %, S3 23.2 %, S4 78.3 %, pooled 76.1 %; none of the
kept words has zero coverage (pooled 8.7 % in (0, .25], 15.3 % in (.25, .5]).
Causes (strictest label variant under which the widened decision keeps the
word): acoustic 92.3 %, 40 ms label padding 7.7 %, gap merging 0 %. 87.9 % would
also be kept without the 80 ms widening; widening never rescues a dropped word.
So about three quarters of the ceiling is genuine overlap with target speech,
and most of the rest is partial overlap at word edges, not label slop.
Removed correct target words: 157 of 39275 in S1-S4 (0.4 %) and 128 of 11481 in
S0 (1.1 %); 55 % (S1-S4) and 70 % (S0) have spans with no target frame at all
(timestamps in labelled pauses), the rest partial coverage.

## Noise twin sets: full render (handoff note, 2026-10-22)

1. Queued chain (orchestrator go): w0-render-noise-dev -> w0-noise-dev-check -> w0-noise-dev-worklist -> w0-noise-dev-asr (gpu:shared 8G) -> w0-noise-dev-refs; w0-render-noise-test (after dev render) -> w0-noise-test-check -> w0-noise-test-worklist -> w0-noise-test-asr (after dev ASR) -> w0-noise-test-refs.
2. Outputs: data/harness/sets/noise-{dev,test}-v1/ (HASH, manifest, 2336 mixtures each) and data/harness/asr/noise-{dev,test}-v1/{asr.jsonl, asr.meta.json, words.jsonl}; re-draw rates in runs/W0/analysis/redraw-noise-{dev,test}-v1.json.
3. The *-check jobs exit 1 (stopping ASR) if any family/SNR cell's re-draw rate exceeds 20 %: then report to the orchestrator before anything else.
4. Remaining: record both HASHes in CONTRACT NOTES; record dev's per-cell re-draw rates below; verify noise-dev-v1 enrollment files equal dev-v1's by CONTENT.sha256; tell W0F (a9b5799872be09dee) when noise-dev-v1's words.jsonl exists. noise-test-v1 is sealed: never scored or inspected.
5. Limitation (accepted, not a design change): at 0 dB the noise family under-represents loud impulsive sources (they clip and are re-drawn; smoke rate 12.5 % per family).

### Noise twin sets: re-draw rates and the test check (W0F, taking over 2026-10-23)

**Re-draw rates.** A family's MUSAN file is re-drawn for all four SNRs
together, so every SNR cell of a family has the same rate. Almost every re-draw
is triggered at 0 dB. Files `runs/W0/analysis/redraw-noise-{dev,test}-v1.json`.

| set | noise family | music family | triggered at 0 / 5 / 10 / 20 dB (noise; music) |
|---|---|---|---|
| noise-dev-v1 | 33/292 (11.3 %) | 9/292 (3.1 %) | 33/8/1/0; 9/2/1/0 |
| noise-test-v1 | 64/292 (21.9 %) | 8/292 (2.7 %) | 64/18/4/2; 8/2/1/0 |

**The test check.** w0-noise-test-check stopped the test chain by design: the
noise family's 21.9 % exceeds the pre-stated 20 % line in every cell. Dev
passed.

**Orchestrator decision: accept and disclose, no re-render.**
- The comparison is paired, B against the front end on identical mixtures. The
  skew in which MUSAN files appear limits how far the result generalises, not
  whether it is valid.
- Changing the render now would be a post-hoc design change.
- The test worklist, ASR and refs were requeued without the check dependency
  (same reviewed code). The test transcripts are never scored or inspected.

**The dev/test asymmetry (11.3 % against 21.9 %)**, checked against manifest
metadata only (noise family, 0 dB groups):
- Louder inherited targets are re-drawn more often within each set: the
  median requested target level is -23.0 dBFS for re-drawn groups against
  -27.2 for the others in dev, and -22.7 against -28.3 in test.
- The inherited target levels of the two sets barely differ: q10 / median /
  q90 are -32.8 / -26.7 / -22.0 dBFS in dev and -32.7 / -27.1 / -21.3 in test.
  About 94 % of groups are unlimited (peak gain 0 dB) in both.
- At equal target level, test re-draws far more often:

  | target level (dBFS) | dev | test |
  |---|---|---|
  | below -30 | 1/82 (1 %) | 1/80 (1 %) |
  | -30 to -26 | 8/82 (10 %) | 4/86 (5 %) |
  | -26 to -23 | 8/78 (10 %) | 23/65 (35 %) |
  | above -23 | 16/50 (32 %) | 36/61 (59 %) |

- So louder targets explain only a small part of the asymmetry. The rest is
  more likely the composition of the test split's MUSAN noise pool (more
  high-peak, impulsive files). That was not checked: it would need the test
  audio, which is sealed.

**Limitation, disclosed.** At 0 dB the noise family under-represents loud
impulsive sources, because they clip and are re-drawn. Test is affected more
than dev (21.9 % of groups re-drawn against 11.3 %), and dev numbers may not
transfer to test's mix of noise sources in that cell.

**noise-dev-v1 complete (2026-10-23):**
- The chain ran in full: render, check, worklist, ASR, refs.
- HASH 8677da54...aae2, recorded in CONTRACT NOTES.
- Its enrollment files equal dev-v1's by CONTENT.sha256 (4898 of 4898), and
  enrollment.jsonl is byte-identical, so dev-v1 profiles carry over.
- B's identity equals dev-v1's.
- noise-test-v1 (sealed): worklist, ASR and refs ran (requeued without the
  check). HASH 70e3d205...dccc, in CONTRACT NOTES. Its enrollment files equal
  test-v1's by CONTENT.sha256 (5114 of 5114), enrollment.jsonl is
  byte-identical, and B's identity equals dev-v1's. Only listings and
  identities were read, never a transcript.

## Noise twin re-draw smoke (40 dev targets, 10 speakers; nothing frozen)

Re-draws are per family (all four SNRs share one MUSAN file): noise family 5/40
targets (12.5 %), all triggered at 0 dB (one also at 5 dB); music 3/40 (7.5 %),
all at 0 dB (one also at 5 and 10 dB). Inherited ambience: DEMAND 48, SLR28
isotropic 32 of 80 groups; its SNR quantiles (min/25/50/75/max) 15.4 / 18.8 /
23.6 / 29.3 / 38.5 dB.

### Stage `scorecontent` (W0F: content identity of score directories)

The trigger was a sol review of W5's identity check (HIGH). `evaluate`'s score
identity names the scorer factory, its argument strings and the set, but not
the scorer's code, checkpoint or recalibration bytes. `frontend_eval`
therefore combined half-A and half-B score directories even when the
checkpoint at the same path changed between them.

The fix leaves IDENTITY.json and every existing calibration unchanged. Score
directories gain a sidecar, `scores/CONTENT.json`, that records the scorer's
code and loaded files. It has to match wherever directories are combined.

| round | scope | findings | response |
|---|---|---|---|
| r1 | the patch at 8d5dec0 | 4 high, 2 medium | spawn workers, with a code-change regression through run_scoring; the probe keeps scoring's cwd and resolves paths in the child at open time; read-write opens included; native and subprocess loaders documented as a limitation and verified absent (below); backfill checks symlink chains by lstat; the caller's import paths and device env preserved (CUDA_VISIBLE_DEVICES part of the identity); a failed warm-up refused |
| r2 | the r1->r2 delta | 3 high | the probe sets sys.path to exactly the caller's; one shared `walk()` resolves paths as the kernel does, component by component (links expanded where met, `..` applied to the resolved prefix), used at capture and in backfill |
| r3 | the r2->r3 delta | 1 high, 1 medium | the first `""` on sys.path becomes multiprocessing's ORIGINAL_DIR, as under spawn; failed opens dropped (os.stat gate), and walk() refuses missing or non-directory intermediates |
| r4 | the r3->r4 delta | verified by the orchestrator | closed at the full patch sha256 05a60786...abcd4 |

Every finding has a regression test that failed on the previous round and
passes on the next (tests/test_W0_score_content.py, 20 tests). The W0 scorer
digest (ea150eb5...a8b7) is unchanged. Neither evaluate.py nor
frontend_eval.py is in `pvad.identity.w0_identity`'s mixer closure (checked in
a fresh interpreter), so W3's and W5's rendered artefacts are unaffected.


- **What it is:** `evaluate.content_identity(spec, args)` records the scorer's
  code closure and the SHA-256 of every file it reads while it is built and
  warmed up. It is measured in a fresh interpreter with the caller's cwd,
  sys.path and environment, which `run_scoring`'s spawn workers also inherit.
  The record is written to `scores/CONTENT.json`, bound to the score identity.
- **Where it is enforced:** `frontend_eval.load_filter` combines score
  directories only if their content identities are equal.
- **Older directories:** `evaluate backfill-content` records the content of a
  directory scored before this existed. It does so only if every traversed
  symlink (by lstat) and every real target (by stat) is older than its
  COMPLETE.json.
- **The guarantee is against accidents in this checkout.** Not covered:
  - files read only after the warm-up;
  - files opened by native code or by subprocesses, outside Python's audit
    hooks;
  - deliberate tampering with mtimes.
- **Native and subprocess loads checked empirically** (strace -f on the
  content probe, 2026-10-23, `drafts/strace_check.py` and `strace_check.json`).
  For each scorer below, no regular, non-library file was opened for reading
  outside the audit hook. No openat call was split in the logs.

  | scorer | non-library files seen by strace | seen by the hook |
  |---|---|---|
  | W1 factory, Stage D raw | 5 | all 5 |
  | W1 factory, Stage D asnorm | 8 | all 8 |
  | W3 pvad, M-film_cos-s0/final.pt | 4 | all 4 |
  | W0 energy gate | 0 | - |
  | W0 keep everything | 0 | - |

  These are the scorers this experiment combines. Any new scorer that loads
  natively or through a subprocess would need its own check.
- **W1 Stage D 00-05** (runs/W1/eval/*/dev-v1-A) are backfill-eligible, with
  no rescoring: 31-34 covered files each, no symlinks, none newer than
  COMPLETE.json (re-checked with the r3 walk). Each needs
  `./python -m lfspk.harness.evaluate backfill-content --out <dir>` after the
  commit.

### Stage `supersession` (W0F: replacing a registered confirmatory checkpoint)

**Trigger:** AJ decided to fix W5's training and re-register. R1-s0 is
superseded as the confirmatory checkpoint before any stage B ran on it, and it
may be evaluated later as exploratory only.

**R1-s0's dev stage-A outputs were moved, not deleted**, to
`runs/W5/masks_quarantine_R1-s0_20261023/`:
- analyse() on 770 dev-v1 mixtures, with no COMPLETE.json, no stage B, no
  transcripts and no metrics; never inspected;
- QUARANTINE.json lists the files with a listing hash;
- the ledger's two incomplete stage-A start events for R1-s0 (runs 270dfb61
  and 11e5a428) stay, because the ledger is append-only.

**The rule (DESIGN fe-10, "Supersession").**
- The anchors form a strictly ordered, single-parent chain REGISTER,
  SUPERSEDE, REGISTER, ... in HEAD's history.
- A SUPERSEDE names the sha of the preceding REGISTER. In RESULTS.md it turns
  exactly that valid line into the placeholder plus one
  `superseded-checkpoint` line.
- It is valid only if no stage-B run of the old sha, started or complete,
  began before the SUPERSEDE.
- A superseded sha cannot be registered again.
- At HEAD the file holds exactly the lines the chain implies.
- The old checkpoint can only be exploratory, and it never blocks the new
  one.
- The commit format is agreed with W5.

| round | scope | findings | response |
|---|---|---|---|
| r1 | the patch at 3d395e1 | 3 P2, 1 P3 | the veto is limited to runs that began before the SUPERSEDE (run HEAD not a descendant of the anchor; completes judged by their start; headless or orphaned events count as before); each REGISTER's post-image holds exactly one valid line (restored); the evaluator's ledger is passed to every registration lookup; every keyword line at HEAD is validated, malformed ones included |
| r2 | the r1->r2 delta | clean | closed at the full patch sha256 5a7ced37...3314 |

Each r1 finding has a regression test that fails on r1 and passes on r2
(`SupersessionReview1Test`), next to `SupersessionTest` (5 tests).
Unchanged:
- the real HEAD registration dict;
- the identity shape when nothing was superseded;
- pvad's mixer closure (8 files; none of fe_registry, frontend_eval or
  fe_stage_a/b), so W3's and W5's rendered artefacts are unaffected.
