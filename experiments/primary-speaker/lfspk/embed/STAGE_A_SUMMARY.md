# W1 Stage A summary: which speaker embedder

Intrinsic speaker verification on dev (73 speakers: dev-clean and dev-other;
clean read speech, no added noise). The profile is the mean of 10
enrollment utterances, scored with raw cosine against test segments from a
different LibriVox project where the speaker has one. 95 % CIs come from a
joint speaker bootstrap (1000 resamples). Code: commit 4411471 (scoring),
7927ea9 (paired comparisons), 6bc4fab (tail analysis). Full report:
`/mnt/hd/localflow-speaker/runs/W1/survey/results/intrinsic.md`.

| embedder | params | EER % at 1.0 s, all [CI] | EER % at 1.0 s, half B | impostor pass % at 1 % target miss, 1.5 s, half A [CI] | same, half B | trunk GMAC per s | ms per 1.5 s window (x86, 1 thread) |
|---|---|---|---|---|---|---|---|
| redimnet2-b2 | 3.7 M | 2.26 [1.57, 3.34] | 2.78 | 0.25 [0.02, 0.79] | 11.5 | 0.45 | 29 |
| wespeaker-r34lm | 6.6 M | 2.34 [1.40, 3.59] | 2.78 | 0.43 [0.06, 1.06] | 6.3 | 2.26 | 35 |
| wespeaker-campp | 7.2 M | 2.36 [1.45, 3.56] | 2.95 | 0.55 | 9.7 | 0.55 | 22 |
| redimnet2-b0 | 1.1 M | 2.89 [2.04, 3.95] | 3.46 | 0.75 [0.12, 1.60] | 12.5 | 0.15 | 25 |
| ecapa-vox | 20.8 M | 2.82 | 3.26 | 0.89 | 11.3 | 1.90 | 77 |
| titanet-l | 22.1 M | 1.97 [1.33, 3.03] | 2.40 | 0.95 | 24.2 | 1.76 | 81 |
| titanet-s | 6.8 M | 3.03 | 3.58 | 3.18 | 53.3 | 0.33 | 29 |

All seven convert to Core ML ML programs (float16, macOS 14) with ordinary
conv, matmul, normalisation and softmax ops. Conversion was checked on Linux;
nothing was run on Apple hardware.

**Decisions.**
- Shortlist, by the pre-stated rule (half-A operating point at 1.5 s; the
  half-A EER winner is the same model): **redimnet2-b2** (primary),
  wespeaker-r34lm, and redimnet2-b0 as the cheapest point.
- B2 matches TitaNet-L at a sixth of the parameters (EER difference at 1.5 s:
  -0.05 points [-0.34, 0.18]).
- B0 is non-inferior to TitaNet-S on the operating point (-2.7 points; the
  CI upper bound of +0.45 is below the +10 margin).
- AS-norm cohort normalisation gave no reliable gain for the shortlisted
  models, so raw cosine is the default. AS-norm stays a Stage B variant.
- 10 enrollment dictations beat 3 at 1 s. Going from 10 to 30 brings a
  small, inconclusive further gain.

**The main finding: one speaker sets the tail.** For one dev speaker (1988),
every embedder scores the test recordings (a different LibriVox project) at
impostor level: median similarity 0.12 (B2) and 0.21 (r34lm), against about 0.55 for typical
speakers. That speaker alone accounts for 39-62 % of all target misses at the
1 % threshold (30-48 of 77 misses, depending on the model and segment
length). At 1.5 s, 90 % of misses come from 3-7 of 73 speakers, and 61-67 of
73 speakers never miss a segment (at 1.0 s, 3-13 speakers carry 90 %).
wespeaker-r34lm also has a second outlier (2277, 25 of 114 segments missed),
which is much milder for the ReDimNet models (4-6 misses). So the risk is "a
few users whose recording setup changes drastically", not a broad one.
Exploratory, with 1988 removed: B2 at 1.5 s has EER 0.90 % [0.55, 1.27] and
lets 0.81 % [0.24, 1.54] of impostor segments through at 1 % target miss.
What this means for the product:
- the profile must follow the user across setups (Stage C tests that);
- LocalFlow needs a guard for the case where all of the user's words score
  low, for example never removing more than a bounded share of a dictation;
- the word threshold must be conservative.
We did not listen to the audio. Whether 1988's test project is a different
recording chain or a corpus labelling error is unknown.

**Caveats.** Clean read speech: noise and reverberation (Stage A2) wait for
W0's mixer. With 73 speakers the CIs are wide, and the operating-point CIs
especially so. TitaNet's possible exposure to LibriSpeech training speakers
stays unestablished; the descriptive gap is no larger than the other
models'.
