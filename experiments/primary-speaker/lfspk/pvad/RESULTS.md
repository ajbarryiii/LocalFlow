# W3 personal VAD: results

Status: in progress. No dev numbers yet. DESIGN.md is the pre-registration.

## Verification of components (no data)

- Front end (`features.py`) against NeMo `AudioToMelSpectrogramPreprocessor`
  with Parakeet's settings (128 mels, n_fft 512, 25/10 ms, per-feature
  normalisation, dither 0): max abs difference 1.0e-4 on 3.0 s, 5.0 s and
  0.06 s of random audio and on a ragged batch (2026-10-21, by hand, ./python-nemo).
  Analytic Hann window and Slaney filterbank versus Parakeet's exported
  constants (`parakeet-ios/final-memory-20261005/native/frontend.f32bin`, sha256
  efe8a64a...20d3): 2.4e-7 and 3.7e-9 max abs (unit test).
- Cost (analytic, checked against `torch.utils.flop_counter` to 1 %):

| size | conditioning | PVAD params | MACs / s |
|---|---|---|---|
| S | none / concat / film / film_cos | 96,675 / 118,243 / 158,947 / 162,979 | 4.71 / 5.17 / 4.73 / 4.83 M |
| M | none / concat / film / film_cos | 200,307 / 226,483 / 287,539 / 292,531 | 9.83 / 10.52 / 9.86 / 10.01 M |
| L | none / concat / film / film_cos | 340,803 / 371,587 / 452,995 / 458,947 | 16.80 / 17.72 / 16.83 / 17.03 M |

- CPU latency, untrained weights, torch 2.11, one thread on this host's x86_64,
  5 repeats (smoke): 0.17-0.61 ms per audio second for the network, 0.41-1.05 ms
  with the front end. Final numbers will use 20 repeats on trained checkpoints.

## Sol-loop log

| round | scope | findings (H/M/L) | fixed | rejected |
|---|---|---|---|---|
| core-r1 | 4194eeb: design + all non-W0 components | 1 / 9 / 2 | all 12 | none |
| core-r2 | ef79d24 fix diff | 0 / 2 / 0 | both | none |
| core-r3 | d995d90 fix diff | 0 / 2 / 0 | both, by removal (orchestrator decision) | none |
| core-r4 | 77f1d59 fix diff | 0 / 0 / 0 | - | - |

| train-r1 | c69921f: W0 adapter, bank build, dev monitor, resume, launcher | 1 / 4 / 1 | all 6 | none |
| train-r2 | 7c5b9b7 fix diff | 0 / 2 / 2 | all 4 | none |
| train-r3 | 583c172 fix diff | 0 / 0 / 1 | 1 (verified by the orchestrator, no round 4) | none |

| eval-r1 | 9ac4ff3: harness factory, comparisons and selection, recal fit, D1 | 0 / 4 / 1 | all 5 | none |
| eval-r2 | dcbc861 fix diff | 0 / 2 / 1 | all 3 | none |
| eval-r3 | 4438ab6 fix diff | 0 / 0 / 1 | 1 (verified by the orchestrator) | none |

Eval stage clean after 3 rounds: 6 medium and 3 low findings, all fixed, none
rejected. r3 low: an empty D1 population raised before writing attrition; it
now reports an inconclusive result with the counts.

Train stage clean after 3 rounds: 1 high, 6 medium, 4 low findings, all fixed,
none rejected. r3 low: the resume check refused "cuda:0"; it now compares
torch.device(...).type.

Core stage clean after 4 rounds: 1 high, 13 medium, 2 low findings, all fixed,
none rejected.

core-r1 fixes. High: (1) enrollment/mixture chapters could coincide through a
silent fallback; replaced by fixed per-speaker pools split by LibriVox project,
else chapter, else utterance (orchestrator rule), checked on every example.
Medium: (2) A1 saw no absent-target examples; one shared example stream for
every run, with independent RNG streams per example; (3) missing bank variants
silently substituted; now an error, plus `EnrollmentBank.check`; (4) channel
match drawn per profile; now per dictation; (5) CostReport omitted the
embedder; now required (params from the embedder or explicit, MACs explicit);
(6) gated update plus recalibration ran two PVAD passes but counted one; now one
shared pass; (7) EER without interpolation; now interpolated between bracketing
operating points; (8) training overwrote its input config.json; metadata now
goes to run_meta.json; (9) selection rule not unique; fixed candidate order,
single reference, non-inferiority margin, selection on dev half A, report on
half B; (10) H4 lacked a non-inferiority criterion; margin +0.02 with an exact
paired-CI rule. Low: (11) budget denominator quoted wrongly; now the contract's;
(12) monitor lacked AP for ns and ntss; added. Also folded in: joint speaker
bootstrap across roles (orchestrator rule), with histogram-based frame
statistics.

core-r2 fixes. Medium: (1) probability-domain histograms collapse saturated
scores (0.9999 vs 0.9998 gave AUC 0.5); now logit-domain bins computed from
logits, with an error bound per statistic and a saturation regression test;
(2) every enrollment draw rescanned the bank's channel column (about 22 ms);
catalogues are now cached at construction (0.08 ms per draw on a 144K-row
synthetic bank). Also folded in: the orchestrator's dev change (73 speakers,
W0's canonical stratified halves) and its preference to drop the 194
`same_chapter` train speakers as targets (kept as interferers).

core-r3 fixes. Medium: (1) exact points (float32 probabilities) and histogram
CIs (logits) could rank scores differently; (2) the point-estimate binning bound
did not bound CI endpoints. Per the orchestrator, simplified instead of
patched: one score representation (float64 target log-odds from logits)
everywhere, and exact weighted rank statistics per bootstrap resample
(`FrameRanks`, tie-grouped once, reweighted per resample); histograms and error
bounds deleted; both reviewers' saturation fixtures kept as tests.

train-r1 fixes. High: (1) resumed bank builds could reuse stale shards;
shards now carry an identity record (embedder and weights hash, W0 code and
corpus index hashes, bank code hash, seed rule, devices, shard contents),
checked on reuse, on merge and after each shard renders. Medium: (2) training
resumed without checking the experiment; checkpoints carry an identity record
compared on resume (declared-safe fields only may change), run_meta.json is
written once, finished or stale directories are refused; (3) CUDA determinism
claimed but not enforced; deterministic algorithms on, ops without a
deterministic CUDA backward replaced, GPU resume equality checked (bit-identical
on toy data); (4) dev monitor embedder not checked against the bank's; now
refused on mismatch; (5) the monitor accepted any frozen set; non-dev sets are
refused before any audio is read. Low: (6) short enrollment streams were
recorded as 10-dictation profiles; such speakers are now left out and listed.

train-r2 fixes. Medium: (1) CUBLAS_WORKSPACE_CONFIG could change after cuBLAS
was in use; now set at module import before torch, and deterministic CUDA
training refuses a wrong value or a late setting; (2) concurrent smokes shared
one directory; each invocation now gets its own. Low: (3) the GPU resume check
could silently run on CPU; it now requires CUDA, checks that CUDA was used and
records the device (rerun: RTX 5090, bit-identical); (4) warn_only was not
restored; now preserved.

eval-r1 fixes. Medium: (1) the CLI order of candidates decided the selection;
candidates are now identified from their checkpoints' run_meta and sorted into
the fixed order, and A1/A5 or a missing candidate are refused; (2) points and
G came from each directory's results while CIs used the intersected coverage;
all selection quantities are now computed from the saved scores on one shared
population, and unequal coverage is refused; (3) D1's swapped profile could
contain the scored utterance; it now excludes every utterance of the
interferer used in any mixture and prefers other projects, recording the
relation; (4) the swapped-AUC criterion was invalid (overlap frames stay
positive); replaced, before any data, by a paired single-speaker-frame
log-odds criterion (swapped AUC kept as a diagnostic). Low: (5) the CostReport
now says update_macs counts the embedder trunk only. Also: float16 score files
are refused, and a parity test pins compare.py to W0's compute_metrics.

eval-r2 fixes. Medium: (1) the paired log-odds D1 criterion passed on mere
logit contraction or mixture-wide shifts; replaced (orchestrator decision,
before any data) by per-mixture single-speaker AUCs under own, swapped and
random profiles (plus an unrelated same-sex control): identity iff CI(mean
AUC_swap) < 0.5 and CI(mean(AUC_own - AUC_random)) > 0; (2) selection no
longer checked frozen-set provenance; every evaluation's results.json must
name the requested set id and hash. Low: (3) D1 attrition is reported by
speaker, role and reason, and the conclusion is scoped to the retained
population.

Post-close changes, checked by the orchestrator without a review round:
3cb6888 (parity fixture gets synthetic enrollment rows for W0's eval-r4
coverage guard; compare.py applies W0's expected-key rule) and e9a66e5 (the
W0 code hash in bank-shard and checkpoint identities covers only the harness
modules the mixer imports, computed in a fresh interpreter: __init__,
activity, channels, corpora, forced, mix, rirs, util; data inputs stay covered
by W0's index and alignment hashes), and 91119fc (oracle-relative S0
guardrail G after contract e4782a5; `compare.s0_versus_oracle`; `paired` and
`system_points`, imported by W1, unchanged). The first bank build was restarted after
e9a66e5; its two old-identity shards are kept in runs/W3/emb/stale-old-identity/.

Bank sanity on train shard 0 (25 speakers, redimnet2-b2): unit norms; clean
built-in same-speaker cosine 0.81 vs 0.14 across speakers; clean vs
contaminated twin 0.85; built-in vs headset of the same utterance 0.95.

Toy smoke (2026-10-21, not a result): on tone "speakers" with equal-level
interferers, 600 CPU steps at size S, S4 frame AUC target vs interferer-only:
none 0.80, film_cos 0.91, film 0.93, concat 0.94. It only shows the
conditioning path can learn identity; toy data says nothing about the ranking.
