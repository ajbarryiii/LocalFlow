# W4 design: protecting the stored voiceprint

Status: design, written before any real run (2026-10-21). Changes after review
are logged at the bottom with the reason.

## 1. Question

AJ will allow LocalFlow to store a voiceprint only if (1) it is adequately
secured and (2) it is not easily reversible: someone who breaks the security
barrier must not be able to use it to reproduce his voice. W4 answers:

- how to store it on macOS (design only, `STORAGE.md`; no LocalFlow code);
- how much a stored profile helps an attacker clone the voice, before and after
  candidate protection transforms, measured end to end and compared with what
  the same attacker gets from a few seconds of real audio;
- what each protection costs the scorer, and whether it survives background
  adaptation;
- which protection to recommend, and what it does and does not guarantee.

## 2. Threat model

### Assets

1. **Voice reproduction**: the ability to make audio that a person or a
   speaker-verification system accepts as the user (fraud calls, voice-ID
   bypass at banks, impersonation).
2. **Linkability**: matching the profile to the same person in another system
   (another app's voiceprint, a database of public recordings).
3. **Attributes**: sex and age inferred from the profile. LibriSpeech labels
   sex only, so age is discussed but not measured.

### What the profile is

Per W1/orchestrator (2026-10-21): one L2-normalised speaker centroid plus a
dictation count per microphone route (1-3 centroids), plus global parameters
that are not speaker-specific (cohort statistics from public train speakers,
calibration-head weights) that ship with the app and are not secret. Anything
speaker-specific W1 adds later (running second moments, per-user calibration)
is extra leakage and must be put through the same analysis.

### Adversaries

| id | capability | relevant condition |
|---|---|---|
| A0 | Steals the powered-off Mac or its disk (FileVault on), or a Time Machine disk | (1): must learn nothing |
| A1 | Copies files out of the user's home folder (malware without keychain access, a misdirected backup or sync, a support bundle, a pipeline-history export) | (1): the copied profile must be ciphertext |
| A2 | Runs code as the user in an unlocked session and can read the keychain item (or the decrypted profile from LocalFlow's memory) | (2) |
| A3 | **Full compromise**: everything on disk and in the keychain (profile, keys, wrapped keys), the app, its models, every public parameter (projection matrices, anchor speakers, cohort, seeds), public corpora and public pretrained models, and GPU compute | (2), the case W4 measures |
| A3+ | A3 plus a few seconds of the user's real voice (a video, a voice message) | the realistic baseline for (2) |

Condition (1) is a storage problem (section 4, `STORAGE.md`). Condition (2) is
assessed against **A3**: if the barrier is broken, a key stored next to the
data is broken too. So a keyed transform alone (for example a secret random
rotation) does not satisfy (2); the protection has to come from what the
profile does not contain. A Secure Enclave-wrapped key changes A2 (the key
cannot be exported, so decryption needs code running on that Mac while it is
unlocked) but not A3 in the sense used here, because such an attacker can ask
the Enclave to unwrap; W4 therefore never counts a key as protection for (2).

### LocalFlow already stores the user's voice

LocalFlow macOS today keeps the latest 20 dictation recordings as plain WAV
files in `~/Library/Application Support/LocalFlow/audio/` for replay and retry
(origin/main a442d4a: `Sources/AppState.swift` `audioStorageDirectory` /
`saveAudioFile`, `maxPipelineHistoryCount = 20`; the Settings view says so).
They are not encrypted and not excluded from backup. Any attacker in A1-A3
therefore already holds minutes of clean, close-microphone speech, far more
than the 3-10 s baseline. For a disk attacker the voiceprint's marginal
cloning value is close to zero until that history gets at least the same
protection as the profile. W4 still measures the profile in isolation, because
a profile can leak on its own (a backup or sync path that carries it but not
the audio, an export, a future build without audio history), and because the
recommendation must hold once the history is fixed. `STORAGE.md` covers the
history as part of the storage recommendation.

### What W4 measures for (2)

The question for AJ is not "can the profile be inverted at all" but "how much
does the profile add beyond what A3+ already has". Modern zero-shot cloning
needs 3-10 s of audio. W4 reports, on one scale (acceptance by independent
speaker-verification models of synthesised speech):

- the floor: a different real speaker of the same sex, and unconverted source
  speech;
- the profile, raw and after each protection, after the best attacker W4 can
  build;
- the realistic alternative: 3 s and 10 s of the user's real audio given to
  the same cloning model;
- A3+: 3 s of real audio combined with the raw profile, so the profile's
  marginal value to an attacker who already has a clip is measured, not
  asserted.

### Out of scope (stated, not tested)

- Attacks on the running, unlocked app (memory scraping while LocalFlow holds
  the decrypted profile). Mitigation is to keep the decrypted form short-lived;
  it cannot be prevented while the app works.
- Spoofing LocalFlow's own filter (someone making their words survive
  filtering). Low stakes: the worst case is a stray word kept.
- **Search attacks against the app's own scorer.** With the app and its models
  an attacker can always optimise synthetic speech to maximise the score
  against the profile (black- or white-box). Every useful profile admits this,
  because a profile that can tell the user from a household member carries exactly the
  information such a search climbs. Protection can raise the cost and lower
  the naturalness of the result; it cannot prevent passing LocalFlow's own
  scorer. W4 runs one cheap version of this (the nearest-public-voice attacker,
  section 6) and names the stronger white-box version as untested.
- Human perception of clones. No listening tests (privacy and practicality);
  acceptance by two independent verifiers is the proxy. Verifier acceptance
  and human acceptance can disagree in both directions.
- Stronger cloning systems. W4 uses one public converter (OpenVoice V2) and a
  bridge into its embedding space; a better-resourced attacker (a cloner
  trained to take the profile's embedding directly, or a stronger zero-shot
  model) can do better. All cloning numbers are **lower bounds on risk** for
  the profile conditions and for the audio conditions alike; the comparison
  between them is the result, not the absolute level.

## 3. Hypotheses (pre-stated)

H1. The raw profile is a real cloning asset for A3: clones made from it are
accepted by the independent verifiers clearly above the same-sex
training-speaker baseline (the power check in the section below).
I expect them to fall between the 3 s and 10 s real-audio conditions, because
the cloner's own encoder on real audio sees what the bridge must reconstruct.

H2. Linear protections give no protection beyond the dimensions they discard.
PCA/LDA to d dims, anchor scores with K >= d and a keyed rotation under full
compromise are inverted to the information they keep by a linear attacker. A
stored logistic decision function (w, b) is not a linear map of the centroid,
but its optimality (KKT) conditions reveal a weighted mean of the enrollment
embeddings from (w, b) and the public cohort, so it is a centroid in disguise.

H3. There is no free lunch: inversion quality (identification rank of the
recovered embedding) falls only as fast as verification utility falls, because
both are measures of the same speaker information. A protection is worth
recommending only if it moves clone acceptance down materially while staying
inside the utility budget below; I expect at best a modest reduction (toward,
not to, the floor) from low-bit binarisation of an LDA-reduced centroid.

H4. Additive noise protects only a single snapshot: background adaptation
either decays the noise (it is averaged away by later updates) or, if fresh
noise is injected at every save, multiple snapshots (backups) average it out.

H5. Float templates of affine protections update exactly when the stored state
is the unnormalised projected running mean plus the count (that is the
persisted state, section 6.1); quantised and binary templates need a new update
rule, which costs utility; the logistic function has no exact update without
the past positives.

### Primary quantities (pre-registered; no product verdict built in)

AJ's condition (2) is judged on its own, not relative to audio the attacker
may or may not have. The experiment reports where each protection lands; the
acceptable residual risk is AJ's decision (orchestrator, after review r2).

For a protection P, an independent verifier and an operating point (the
threshold at FAR 1 % and at FAR 0.1 %, set on real dev audio):

    Delta_P = accept(clones from P's template) - accept(floor)

- accept = fraction of synthesised clips the verifier accepts as the target;
- floor = `other-raw`: the same cloning chain driven by a different same-sex
  dev speaker's raw profile (same bridge, same artefacts, wrong person);
- clones from P = the **attack envelope**: per bootstrap resample, the maximum
  over every attack route evaluated for P (section 6.4), so the selection over
  routes is inside the confidence interval (contract rule) and favours the
  attacker.

Reported for every cloned protection, under both verifiers, at both FARs, with
95 % CIs (joint speaker bootstrap):

- (a) Delta_P and its upper bound;
- (b) worst-decile acceptance: the mean per-speaker acceptance of the 10 % of
  targets most at risk (envelope, and minus the floor's);
- (c) success within k = 1, 5 and 20 attempts per target: the probability that
  at least one of k clones is accepted (20 clones per target and condition:
  5 source utterances x 4 seeded conversions; best-of-k by the exact
  without-replacement formula);
- (d) **risk tier** of a distribution-free upper bound on mean excess
  acceptance at FAR 1 %: negligible <= 0.02, low <= 0.05, moderate <= 0.10,
  high > 0.10 (review invert-r4; orchestrator decision).
  - Per target speaker i (one value per target): a_i = the largest acceptance
    rate over attack routes (out of 20 attempts); floors f_i = the primary
    floor's rate (`other-raw`), and separately the matched controls' envelope
    (largest rate over the `|other` routes).
  - Delta_upper = U_{0.025}(mean a) - L_{0.025}(mean f) (Bonferroni, 95 %
    overall). U and L are the hedged-capital betting confidence bounds for
    bounded means of Waudby-Smith & Ramdas (2023, JRSS-B 86(1), "Estimating
    means of bounded random variables by betting"), implemented from the
    paper (`metrics.wsr_upper_mean`, `wsr_lower_mean`, `delta_upper`):
    - c = 0.75, with predictable plug-in bets.
    - Targets are processed in a **pre-registered seeded permutation** of
      ascending speaker id (`metrics.target_order`, seed `ORDER_SEED = 7331`).
      Identifier order could align with strata (review invert-r5).
    - Grid 1/2000, then bisection. Inversion rounds **outward**: the returned
      bound sits at the rejected end of the final bracket, so the confidence
      set is a superset (WSR section 4.4; review invert-r5 #3).
  - **Sampling design (the guarantee is for this design; review invert-r6
    #1 rejected by the orchestrator, reason below).** WSR needs observations with a common
    conditional mean. The headline estimand is defined under a randomised
    design:
    - clone_eval targets are treated as a random sample of speakers;
    - each target's partner is drawn uniformly at random from the eligible
      same-sex train pool, independently of everything else
      (`train_partners`: a seeded uniform permutation of each sex's pool,
      assigned without replacement);
    - the order of targets in the sequential bound is a uniform random
      permutation (`target_order`, ORDER_SEED).

    Under this design the (a_i, f_i) pairs are exchangeable draws with a
    common mean. The coverage statement is about this randomised design, not
    conditional on the realised partner assignment.
    - Drawing partners without replacement from a finite pool is not i.i.d.
      sampling. WSR (2023) treat sampling without replacement separately.
      The orchestrator's reading is that this can only tighten the bound
      relative to the with-replacement model. W4 has not verified that against
      the paper, so the bound is stated as holding under with-replacement
      sampling of partners, and the effect of drawing without replacement is
      unverified.
    - The reviewer's counterexample (40 high-floor units fixed at the start
      of the sequence) is a fixed, non-random design, which the randomised
      assignment and order rule out.
    - U(mean a) alone, with no floor subtracted, is reported beside every
      tier as the conservative companion; it needs no floor model.

    On dev the design does not hold: thresholds are calibrated on the same
    speakers, and partners are reused in a cycle (the reviewer's earlier
    counterexample undercovered at 7.7 %). So dev tiers are **exploratory**.
  - Taking the per-target maximum over routes inflates a_i at chance
    (conservative). U(mean a) alone (floor 0) is reported too and needs no
    floor.
  - Descriptive, not tier inputs: the bootstrap CI of Delta (section (a)), the
    bound at the bootstrap 2.5 % quantile of dev's threshold, and the
    Clopper-Pearson interval on the fraction of **vulnerable** targets (some
    route accepted in at least 5 of 20 attempts). Illustration only, assuming
    independent accepts at a 1 % rate (shared seeds correlate routes):
    1 - 0.99^60 = 45 % of targets would have one chance success over 3 routes
    x 20 attempts, while P(Binomial(20, 0.01) >= 5) = 1.37e-6 per route, at
    most 4.1e-6 over three routes. "Any success" counts are also reported.
- **Aggregation over verifiers:** a protection's tier is the worst tier among
  the verifiers whose power check passed, reported with its coverage ("2 of 2"
  or "1 of 2 verifiers powered") and each verifier's ungated tier. With no
  powered verifier the tier is "insufficient power". Raw is gated like every
  other protection (review clone-r2 #1, #2). Any tier that rests on one
  verifier is stated as such in the report.
- **Target sets and the headline (owner decisions 2026-10-21, revised after
  review invert-r5).**
  - The **headline tier comes from clone_eval alone**:
    `splits.speakers("clone_eval")`, LibriSpeech train-clean-100, 251
    speakers, disjoint from train, dev and test.
  - clone_eval speakers are targets only. Nothing is fitted, selected or tuned
    on them:
    - attackers, bridges and fusion weights come from train and held-out
      train;
    - the FAR thresholds and the protection selection come from dev, applied
      unchanged. Dev is independent calibration (fixes invert-r5 #2).
    - Recording conditions differ between train-clean-100 and dev, so the
      dev threshold need not sit at FAR 1 % on clone_eval. The **achieved FAR
      on clone_eval's own impostor trials** is reported for each verifier and
      FAR (`real_trials_far_at_threshold`). If it is far above 1 %, the floor
      absorbs part of it (the floor is measured at the same threshold), and
      the report says so.
  - **Floors on clone_eval** (fixes invert-r5 #1):
    - Each target gets a **unique same-sex train partner**: seeded
      (`PARTNER_SEED = 7330`), no partner reused, linfn cohort speakers
      excluded.
    - `other-raw`: the partner's raw profile (first 10 cached utterances)
      through `inv+bridge`.
    - `<route>|other`: every route on the partner's own protected template.
    - `other-audio-10s`: the partner's next cached utterances, up to 10 s.
    - The f_i are therefore independent across targets.
    - Partner data and fitting: the partner's 10 profile utterances and its
      other cached utterances (used for `other-audio-10s`) are all among the
      train embeddings and OpenVoice se vectors the attackers, bridge and
      direct routes were fitted on. `other-audio-10s` goes straight from real
      audio to the cloner and uses no fitted model; the other floors do. The
      memorisation effect is reported per route: every route's matched delta
      sits next to the primary-floor delta.
    - The floor is therefore the **training-speaker baseline**, and the tier
      reads "excess over the training-speaker baseline" (review invert-r6
      #2). The attackers, bridge and direct routes were fitted on train
      pseudo-profiles that include these partners, and the direction of the
      effect is not known:
      - clones of a seen speaker may be more faithful to that speaker, which
        lowers their acceptance as the target;
      - fitted routes may also produce coherent voices that cross the
        threshold more often than an unseen speaker would.

      No direction is claimed. The real-audio floor `other-audio-10s` (no
      fitted model) and U(mean a) are reported beside it.
  - **Dev (73)** keeps its within-dev cyclic partners and its own
    thresholds. Its tiers are reported as exploratory and never pooled with
    the headline.
- **Resolution by sample size.** The betting bound never reaches zero. The
  table gives Delta_upper only for the **constant zero-excess cases**: every
  observed a_i equal to every f_i, at the stated rate (`metrics.delta_upper`,
  alpha 0.05, outward inversion). Values are computed by the implementation
  (`clone_exp.resolution_table`, regenerated by a unit test) and rounded UP
  to 3 decimals. It is not a universal minimum: when a protection's rates are
  below a positive floor the bound is lower. For example, a_i = 0 with both
  floors at 0.05 gives 0.040 at n = 73 (review invert-r5 #4).

  | constant a_i = f_i | n = 73 (dev, exploratory) | n = 251 (clone_eval, headline) |
  |---|---|---|
  | 0.00 (no clone ever accepted) | 0.065 | 0.020 |
  | 0.01 | 0.074 | 0.029 |
  | 0.05 | 0.087 | 0.027 |
  | 0.10 | 0.082 | 0.026 |
  | 0.30 | 0.066 | 0.021 |

  In these zero-excess cases the best headline tier is **low**. Negligible
  (<= 0.02) is reached only when nothing at all is accepted (0.020). These
  are properties of the evaluation's size, not of any protection, and the
  report states them.
- **Threshold label.** Every tier is reported as "at the dev-calibrated
  nominal 1 % FAR threshold; achieved clone_eval FAR = x" (per verifier).
  The achieved FAR on clone_eval's own impostor trials always stands beside
  the tier, because recording conditions differ between the splits. In the
  reviewer's synthetic example with shifted scores it was 99.8 %.

A low tier means "this attack suite, with public tools, does not turn the
stored profile into a voice an independent verifier accepts much more often
than clones driven by a same-sex training speaker's profile through the same
routes": **excess over the training-speaker baseline**, at the dev-calibrated
nominal 1 % FAR threshold. It makes no claim against an unseen-speaker
baseline. For example, constant acceptance of 30 % for both the protection
and the baseline gives a low bound (about 0.021) while saying nothing about
how often an unseen speaker's clones would pass. That is why U(mean a), with
no baseline subtracted, and the real-audio floor are reported beside every
tier. It is a lower bound on risk, never a proof of safety (review clone-r5
#2).

**Power check (gates the tiers).** The experiment discriminates only if the
raw profile is clearly risky. The test is the betting **lower** bound of
raw's excess over the primary floor, L_{0.025}(mean a_raw) - U_{0.025}(mean f),
which must exceed 0.10, per embedder and verifier. On the headline it is
evaluated on clone_eval with its independent floors; on dev it is
exploratory. Where it fails, every protection of that embedder, raw included,
gets "insufficient power" from that verifier and its numbers are reported
without a tier (reviews clone-r1 #1, clone-r2 #1). The bootstrap lower CI end
is reported as a descriptive check.

Context, not criteria: `audio-3s` and `audio-10s` (the same cloner on the
user's real audio), and the marginal value of the profile to an attacker who
already has 3 s (`audio-3s+P` minus `audio-3s`).

### What would change the recommendation

The recommendation lists, for each protection, its tier and its utility cost,
and names the cheapest protection reaching each tier. Then:

- Raw clearly risky on the headline split and some protection inside the
  utility budget reaches the best resolvable headline tier (low on 251
  clone_eval targets in zero-excess cases): that protection is the default
  proposal. It is stated as "no measurable excess beyond <tier> with this
  suite and sample", with its point estimates, the exploratory dev results
  and the descriptive bounds. AJ chooses whether that tier suffices.
- Raw clearly risky and nothing inside the budget gets below high: say so
  plainly, give the utility cost of the cheapest protection that does, and
  the option of not storing a profile at all (re-enrolling each session in
  memory).
- Power check fails: no claim about protections from cloning; the
  recommendation rests on inversion (identification, embedding-level spoofing)
  and minimisation, and says the cloning test was not strong enough.

## 4. Storage design (deliverable 1)

`lfspk/protect/STORAGE.md`: location, encryption (AES-GCM, key in the
keychain, optional Secure Enclave wrap), backup and sync behaviour, missing-key
behaviour, deletion and opt-out, exclusion from exports and logs, iOS keyboard
sharing. Every claim cites Apple documentation or is marked unverified. It
reflects LocalFlow as it is today (read-only inspection of
the LocalFlow checkout, commit noted in the document):
non-sandboxed, Developer ID, hardened runtime, one entitlement (audio input).

## 5. Data and splits

Splits from `lfspk/splits.py`; the sealed test split is never read.

- **Train** (train-clean-360, 921 speakers): up to 40 utterances per speaker,
  chosen by a seeded shuffle per speaker. Fits every public transform (PCA,
  LDA, anchors, cohort, quantiser scales), every attacker, and the bridge into
  the cloner's embedding space. Pseudo-profiles: means of random subsets of k
  utterances of one speaker, many per speaker.
- **Dev** (dev-clean + dev-other, 73 speakers, 36 F / 37 M; contract change
  86ef446): every reported number. Per
  speaker the utterances are assigned once, deterministically:
  - Two sides that never share a LibriVox **project** (the closest proxy for
    a recording setup; chapters of one project likely share microphone and
    room) when the speaker's projects allow it, else never share a
    **chapter**, else split within chapters (`separation` = project / chapter
    / none; 39 / 17 / 17 dev speakers). Among feasible splits the largest E
    (up to 20; at least 10) wins, then the smallest profile side. Three short
    dev-other speakers get E of 19, 19 and 10; k = 20 results use the 70
    speakers with a full pool (n reported).
  - **Profile side**: **E** (enrollment pool of 20; profile = E[:k], k in
    {3, 10, 20}, seeded order) and **A** (the attacker's real audio:
    utterances until 12 s; 3 s and 10 s are cut from it). The profile attacker
    and the audio attacker therefore stand in the same session relation to
    the references (review r1 #7).
  - **Verification side** H: **R** (5 utterances: the verifiers' reference for
    the user) and **T** (at least 7: genuine trials that set verifier
    thresholds). Utility probes are all of H.
  - Utility and inversion are also reported on project-separated speakers
    alone (sensitivity).
- clone_eval utility is context only and is reported as point estimates
  without a CI (about 5 M profile x probe trials per protection); the
  selection uses dev's utility with CIs.
- **clone_eval** (train-clean-100, 251 speakers; targets only, the headline
  split, see section 3): roles assigned exactly as for dev (same function,
  same seed). Floors come from unique same-sex **train** partners, one per
  target, never reused (section 3).
- **Embeddings** (shared cache, W1's `load_embedder`; format in CONTRACT
  NOTES): dev and clone_eval full utterances and one seeded 2 s crop per
  utterance; train full utterances. Profile embedders, all provided by W1's
  interface:
  - **ReDimNet2-B2** (`redimnet2-b2`, VoxCeleb2-trained) is the **primary
    embedder for the recommendation**, because it is W1's shortlisted
    product embedder;
  - SpeechBrain ECAPA and NeMo TitaNet-small are secondary evidence.

  Train embeddings are also fed to every attacker.

Caveat (orchestrator, 2026-10-21): NVIDIA lists LibriSpeech among TitaNet's
training data. Dev and test speakers are not in LibriSpeech's training subsets,
but train-clean-360 speakers are, so TitaNet embeddings of train speakers are
"seen" (tighter clusters) while dev speakers are unseen. Attackers and bridges
fitted on train may then be miscalibrated for dev in either direction. W4
reports the train-CV vs dev gap for each TitaNet attacker and treats ECAPA
(VoxCeleb-only training) as the clean primary embedder. **clone_eval
(train-clean-100) is a LibriSpeech training subset too.** TitaNet-small
profiles and the TitaNet-large verifier may therefore have seen those
speakers. ECAPA is the primary profile embedder and WeSpeaker ResNet34-LM
(VoxCeleb2) the primary verifier for every claim that rests on clone_eval;
TitaNet-based numbers on clone_eval are reported with this caveat.

## 6. Method

### 6.1 Protections

Each protection is a public object fitted on train (A3 knows all of it): an
affine base map x -> (x - mu) W and an encoder for the stored bytes.
**Persisted state** (what LocalFlow would write, per microphone route): the
dictation count and the template, nothing else. For float protections the
template is the unnormalised projected running mean of the per-utterance
normalised embeddings (exact background updates; its magnitude is part of
what attackers see). Quantised, sign and noisy templates encode the normalised
projected mean. Noise is drawn once from a CSPRNG and never stored (no seed,
no realisation). Probes are fresh in-memory embeddings, never stored; scoring
is asymmetric (stored side protected, probe not).

**Enrollment anchor (W1 profile format v2, under review; commit b850fce).**
W1's "anchored" update rule also persists a fixed enrollment anchor: a
second speaker-specific vector, essentially a clean early voiceprint. It is
at least as invertible as the running mean and must get the same treatment:
- Every protection applies the same transform to the anchor as to the mean,
  and the attacker gets both stored vectors.
- The anchor is protected **once, at enrollment, and stored byte-identically**
  afterwards; it is never re-protected or re-noised. Two independently noised
  copies (anchor and mean) would be two noisy observations that an attacker
  can average (review invert-r6 #4).
- Any experiment for the anchored rule must test joint disclosure: the
  attacker holds the anchor and the mean together. No experiment now.
- For the inversion and cloning experiments the anchor is the profile of the
  first k dictations and the mean that of all dictations so far. With
  W4's single-snapshot protocol (profile = E[:10]) the two coincide, so the
  current numbers cover the anchor as long as it is protected identically.
- If the anchored rule becomes W1's recommended rule, W4 adds one check
  (no new experiment otherwise): that the rule still works when the stored
  anchor is the protected one (its comparisons run in the protected domain,
  or the unprotected anchor is kept in memory only, like any decrypted
  state). Storing the anchor unprotected while the mean is protected would
  undo the protection.

| name | stored form | grid (all run, all reported) |
|---|---|---|
| raw | float32 unnormalised running mean (W1's persisted format) | - |
| pca-d | top-d PCs of centred train embeddings, float32 | d in {16, 32, 64} |
| lda-d | LDA (within-class whitened) to d dims, float32 | d in {16, 32, 64} |
| quant-b | per-dim uniform quantiser (scales from train), b bits/dim, on raw or lda-32 | b in {1, 2, 4} |
| simhash-m | m sign bits of public Gaussian hyperplanes, on centred raw or lda-32 | m in {32, 64, 128, 256} |
| anchor-K | cosines to K public anchor speakers (train centroids, seeded choice) | K in {16, 32, 64, 128} |
| anchor-K+q1 | coordinate signs of centred anchor scores | K in {64, 128} |
| noise-s | normalise(v + s g / sqrt(p)), v the normalised (centred) state, g standard normal, drawn once | s in {0.25, 0.5, 1.0} |
| linfn | logistic-regression weights (w, b): k enrollment embeddings vs a public cohort of 200 train speakers | - |
| keyrot | Q c, Q a keyed random orthogonal matrix | control, attacked with and without the key |
| combos | lda-32 + noise-0.5; lda-32 + simhash-64; anchor-64 + noise-0.5 | as listed |
| votes (added after review clone-r1 #5) | per-bit vote fractions of the sign code (what a majority-updated sign template must keep) | center+shv128, lda32+shv64 |

The grid is fixed now. Nothing is added after seeing dev numbers without a
logged reason in this file, and every configuration run is reported.

### 6.2 Utility (dev)

Profile = protected mean of E[:k] full-utterance embeddings. Trials: every
profile against every 2 s crop from every speaker's H (target if same
speaker). Primary: **EER on 2 s crops, k = 10**, over all impostors.
Secondary: same-sex impostors only (the second-dictator case), full
utterances, k = 3 and k = 20, minDCF (P_target = 0.01, C_miss = C_fa = 1).
95 % CIs: joint speaker bootstrap (1000 resamples): one speaker multiset is
drawn per resample and a trial is kept, with multiplicity, only when all its
speakers are drawn (m_i for a target trial, m_i m_j for an impostor trial), so
the variance from impostor speakers is not hidden (orchestrator rule,
2026-10-21). Identification rates keep the gallery at its declared size (73,
or 73 + 921) and resample query speakers only (review r2 #5).

**Utility budget** (pre-stated): a protection is inside budget if its primary
EER is at most 15 % relative above raw for the same embedder (point estimate)
and its minDCF at most 0.02 absolute above raw. Word-level harness metrics
(contract) are added once W0's harness is ready, coordinated through the
orchestrator, for raw and the recommended protection only.

### 6.3 Inversion (dev)

Attackers are trained on train pseudo-profiles (pairs: protected template,
raw centroid). Train speakers are split three ways: fit, validation (ridge
lambda, MLP early stopping) and selection. The **selected attacker** for a
protection is the one with the highest mean cosine on the selection speakers;
it is fixed before dev is looked at and gives the primary inversion numbers.
The best attacker per metric on dev is also reported, labelled exploratory
(selected on dev, biased toward the attacker). Attackers:

- `analytic`: the protection's own inverse (exact state inverse /
  pseudo-inverse; dequantisation; signed hyperplane sum; the key for keyrot;
  KKT inversion of the logistic function);
- `ridge`: linear MMSE regression;
- `mlp-s{0,1,2}`: 2 hidden layers, cosine loss, 3 seeds (all reported);
- `knn10`: nearest public voices: score the template against public train
  centroids with the protection's own scorer, average the top 10 (no learning;
  works for any protection that keeps utility);
- `maxmargin` (sign codes): the maximum-margin direction consistent with every
  stored bit; `ridge+cons` (sign and quantiser codes): the ridge estimate
  projected onto the set of directions that reproduce the stored code;
- `seedleak` (noise): replays the noise and undoes it exactly. Models a
  product that persisted a seed or the noise; LocalFlow would not, so it is
  reported as a worst case and never selected. `wrongkey` (keyrot): an
  attacker without the key (A1, not A3), a control, never selected.

Metrics, all with speaker-bootstrap CIs:

- cosine of the recovered vector to the true raw centroid, and to the
  speaker's independent centroid from R (the identity, not the stored vector);
- identification: rank of the true speaker among the 73 dev speakers (R
  centroids), top-1 and top-5 rate (`top1_dev`); and among 994 (dev + train
  centroids, `top1_all`) for linkability;
- embedding-level spoofing: fraction of recovered vectors that the same
  embedder accepts against the R centroid at the raw EER threshold;
- sex leakage: logistic regression on protected train templates, accuracy on
  the 73 dev templates.

### 6.4 Cloning, end to end (dev)

- Cloner: OpenVoice V2 tone-colour converter (MIT; voice conversion
  conditioned on a 256-d tone-colour embedding `se`). Watermark off (it would
  only add a second confound). Audio is never written to disk: it is
  synthesised, resampled to 16 kHz, scored and discarded in memory.
- **Attack routes** to a target `se` (all evaluated for every cloned
  protection; review r1 #6): `inv+bridge` (the selected inversion attacker,
  then a bridge from embedder centroid to `se` trained on train speakers,
  ridge vs MLP chosen by `se` cosine on held-out train speakers);
  `direct-ridge` and `direct-mlp` (trained on train pseudo-profiles straight
  from protected template features to the `se` centroid of the same
  utterances, MSE loss). A protection's clones are scored as the envelope over
  routes (section 3).
- **Route-matched wrong-person controls** (review clone-r1 #2): every route
  is also driven by the partner's protected template (`<route>|other`). Delta
  against the matching route's control is reported next to Delta against the
  registered primary floor. Excess on a direct route counts as identity
  leakage only if it also exceeds that route's matched control.
- Source speech: 10 fixed train-split utterances (5 F, 5 M, 4-8 s); each dev
  target is converted from the 5 sources of its sex, 4 times each with seeded
  draws of OpenVoice's sampled latent (tau = 0.3): 20 attempts per target and
  condition. `src_se` comes from the source utterance itself. The seed of
  attempt (target, source, draw) is shared by every condition, so equivalent
  conditions give identical conversions. Fusions whose selected weight is 1
  (= `audio-3s`) or 0 (= the route) are aliases and are not synthesised;
  `se-centroid` is embedder-independent and synthesised once.
- Conditions (target `se`): `audio-10s`, `audio-3s` (OpenVoice's encoder on A);
  `se-centroid` (OpenVoice's encoder on the same E[:10] audio the profile was
  built from: what a lossless bridge would give); for each cloned protection P,
  every route above; `audio-3s+P` (a fixed fusion of the `audio-3s` se and P's
  route output, weight chosen on held-out train speakers from {0, 0.25, 0.5,
  0.75, 1} by se cosine to the speaker's full-audio se). Floors:
  - `other-raw` (primary floor): another speaker's raw profile through
    `inv+bridge`. On clone_eval that speaker is the target's unique train
    partner; on dev it is a fixed different same-sex dev speaker.
  - `other-audio-10s`: that speaker's real 10 s.
  - `source`: no conversion.
- **Embedders cloned:** redimnet2-b2 (primary) and ecapa-vox; titanet-s too
  if the plan stays within the GPU budget. If it does not, TitaNet-s is
  dropped from cloning first: it is the weakest, and the TitaNet family may
  have seen clone_eval speakers. It keeps its utility and inversion results.
- Protections cloned (staged, orchestrator 2026-10-21): raw always; from the
  fixed list lda32, lda16, lda32+sh64, lda32+q1, anchor32, center+noise0.5,
  linfn, only those inside the utility budget (section 6.2) for that embedder;
  plus up to 3 more inside the budget with the lowest selected-attacker
  top-1 identification. Decided from utility and inversion numbers only,
  before any cloning number exists, and logged here with the numbers. keyrot is
  not cloned: with the key its template is the raw template rotated, inverted
  exactly (unit test and inversion results), so its cloning risk equals raw's
  by construction.
- Cost (measured 2026-10-21, RTX 5090, shared lease, peak 1.8 GB): 0.019 s per
  conversion of a 5.5 s clip plus 0.007 s for both verifiers (0.026 s per
  clip). Each cloned protection adds up to 9 conditions per embedder (3 routes,
  3 matched controls, 3 fusions, fewer where fusions alias); each condition is
  324 x 20 = 6480 clips over dev and clone_eval. The full eight-protection list
  on two embedders would be up to 151 conditions, about 7.1 GPU-hours.
  Budget approved by the orchestrator: 8 GPU-hours on a 4 GB shared lease.
  The staged selection is enforced in code: `prepare --only` and
  `synth --only` are mandatory and must match. `clone_exp plan` counts the
  non-aliased conditions, clips per target split and expected hours. That
  output goes into the committed selection log before the first synth job.
  The log also records the evidence: each embedder's full inversion
  `summary.tsv` rows and their SHA-256, including the protections not
  selected. Next to every row it records the utility numbers against the
  budget (EER relative to raw, minDCF minus raw, within budget or not).
  Writing the log is refused when:
  - a selected non-raw protection is outside the utility budget;
  - the rationale is empty.

  `synth` is refused when (review clone-r4):
  - score files from an earlier synthesis already exist;
  - the plan exceeds `--max-gpu-hours` (default 8);
  - its selection-log commit differs from the one recorded by the first
    synthesis in the append-only ledger `runs/W4/clone/ledger.jsonl`, unless
    `--new-preregistration "<reason>"` is given.

  Every synthesis start is appended to the ledger, together with its
  selection-log commit and plan hash, and the commit is written into every
  scores file. `stats` reports the whole ledger and lists any new
  pre-registrations. There is one experiment ledger: real synthesis writes
  only to the canonical directory `runs/W4/clone/`, whatever `--out` says.
  `--smoke` (2 targets per split) must write elsewhere, skips the gate and
  never touches the ledger (review clone-r5 #1). The utility-budget check
  uses the full-precision EER and minDCF from each protection's result JSON
  (with its SHA-256); the rounded summary rows are kept for reporting only
  (review clone-r5 #3).
- Independent verifiers: WeSpeaker ResNet34-LM (VoxCeleb2-trained) and NeMo
  TitaNet-large (orchestrator: W1 treats it only as an upper bound). If W1
  ships a model of the same family as a verifier, that verifier is dropped
  from the conclusion. Neither is used for profiles, attackers or bridges.
  - **Dependency on W1's pick (2026-10-21).** `wespeaker-r34lm` is on W1's
    Stage A shortlist. While the product embedder is `redimnet2-b2`, it stays
    a valid independent verifier. If W1's later stages switch the product
    pick to r34lm, conclusions rest on TitaNet-L alone, or on a third
    independent verifier such as CAM++ (`wespeaker-campp`, not shortlisted).
    TitaNet-L carries the clone_eval familiarity caveat (section 5).
- Score: cosine of the synthesised clip to the target's R centroid. Thresholds
  from real dev audio with the same protocol: genuine = T utterances vs own R
  centroid, impostor = other dev speakers' T utterances; thresholds at FAR =
  1 % and 0.1 %. Metrics as listed in section 3 (a)-(d), plus mean scores.
  CIs: joint speaker bootstrap; within each resample the thresholds are
  recomputed from the resampled real trials, a clip counts with the
  multiplicity of every speaker it involves (target; and the other speaker
  for floors), and envelopes take the maximum over routes.

### 6.5 Adaptation compatibility

Per dev speaker, a stream of E (up to 20 dictations). At n = 3, 10, 20 compare
the primary EER of (a) the exact running mean protected afterwards (needs the
raw mean, i.e. not protected at rest) with (b) protected-domain updates:

- float protections: running mean in the projected space from (template,
  count) (exact; unit test);
- quantised: stochastic rounding of the running mean (unbiased);
- simhash: per-bit vote counts versus stored signs only with a stochastic flip
  rule. The extra leakage of the counts is measured in 6.3 as the protections
  `center+shv128` and `lda32+shv64` (full attack suite, identification,
  spoofing; review clone-r1 #5);
- noise: decay of the injected noise under updates, and the snapshot-averaging
  attack (attacker holds N saved versions, N in {1, 2, 5, 10}) when fresh noise
  is injected at each save. Recovery is measured against the normalised
  projected running mean, the state the templates encode (review clone-r1 #4);
- linfn: no exact update. Adding a dictation changes (w, b) and therefore the
  sigmoid weight of every earlier dictation, so refitting needs the past
  positives (stored audio-derived embeddings, which the profile must not keep).
  Not simulated; any approximate update would be a new protection needing its
  own inversion analysis.

## 7. Seeds, reproducibility, provenance

Every random choice (utterance selection, crops, hyperplanes, anchors, noise,
attacker init, bootstrap) derives from a named integer seed recorded in the
run's `config.json`; the run command and git commit are recorded with outputs
under `/mnt/hd/localflow-speaker/runs/W4/`. MLP attackers run with 3 seeds and
all are reported. Downloaded code and weights (OpenVoice code commit and
checkpoint, WeSpeaker ONNX, TitaNet-large) get URL, licence, SHA-256 and date
in `data/PROVENANCE.md`.

No packages need installing: `./python-nemo` already provides NeMo, librosa
and transformers; onnxruntime is in the venv. OpenVoice's model code is used
from a pinned clone of its repository (commit 74a1d14), importing only
`openvoice.models`, `openvoice.mel_processing`, `openvoice.utils` (no text
front end, no watermark model).

## 8. Risks

- Small dev set (73 speakers): CIs will be wide; differences smaller than the
  CI are reported as not resolved, not as effects.
- Cloner/bridge weakness makes every cloning number a lower bound; a weak
  bridge could make the raw profile look safe. The `audio-*` conditions use the
  cloner's own encoder (no bridge), so the bridge's loss is visible by
  comparing `raw` with an oracle `se-centroid` condition (OpenVoice's encoder
  on the same E audio the profile was built from), added for this reason.
- Verifier artefact sensitivity: synthetic audio may be penalised for
  artefacts regardless of identity; the `source` and `other-*` floors and the
  `audio-*` conditions are on the same footing.
- TitaNet train-speaker familiarity (section 5).
- LibriSpeech read speech, clean channel: real dictations are noisier and
  shorter; utility gaps may widen in the harness.

## 9. Change log

- 2026-10-21: initial design.
- 2026-10-21 (before any run): §2 adds LocalFlow's stored audio history
  (found while writing STORAGE.md). §5 separates E/H by LibriVox project
  first, and §6.2 uses the joint speaker bootstrap: both are orchestrator
  rules for all workstreams.
- 2026-10-21, sol r1 fixes (before any run): absolute primary criterion
  (Delta vs floor, delta = 0.10 at FAR 1 %, envelope over attack routes,
  power check); persisted state defined (float templates are the unnormalised
  projected running mean); profile side holds E and A; attacker selection on a
  third held-out train speaker set, dev-best labelled exploratory; new attacks
  (max-margin and code-consistent projections, KKT inversion of linfn,
  seed-leak worst case); direct protected-to-se cloning routes and validated
  fusion; anchor sign codes are coordinate signs (q1), not SimHash; 5 sources
  per sex; dev = 73 speakers (contract change); metrics named by gallery
  (`top1_dev`, `top1_all`); enrollment pools of 10-20 for short speakers.
- 2026-10-21, sol r2 fixes (before any run): no product verdict in the
  experiment; pre-registered (a) Delta at FAR 1 % and 0.1 %, (b) worst-decile
  acceptance, (c) success within 1/5/20 attempts (20 clones per target), (d)
  risk tiers on the upper bound (orchestrator); identification CIs with a fixed
  gallery; constraint attacks report feasibility and fall back to feasible
  points; linfn has no exact update (text corrected).
- 2026-10-21, sol invert-r3 and clone-r1 fixes (before any run):
  - Tiers now use max(bootstrap upper bound, Clopper-Pearson bound on the
    vulnerable-target fraction). Best tier resolvable on 73 speakers: low.
  - Tiers are gated on raw's power check.
  - FAR threshold is the minimal cutoff; worst decile uses exact boundary
    weight.
  - Quantiser-consistent attack validates codes and reports infeasible cells.
  - Route-matched wrong-person controls; shared seeds and aliases.
  - Vote-count protections added; adaptation noise truth fixed.
  - OpenVoice cache generations validated and recorded.
  - OpenVoice waveform parity test against upstream.
  - Persisted state is float32 (W1 decision; replaces float16 in 7955e75).
- 2026-10-21, sol clone-r2 fixes (before any run): raw is power-gated too;
  aggregate tier = worst among powered verifiers, with coverage disclosed;
  staged selection mandatory in code, `plan` counts conditions and hours
  (budget up to 2.5 GPU-hours); chance arithmetic corrected (1.4e-6, not
  1.6e-5) and labelled illustrative.
- 2026-10-21, sol invert-r4 (before any run): tier input replaced by the
  Waudby-Smith & Ramdas betting bound on mean per-target excess acceptance
  (vs primary and matched floors); bootstrap Delta CI and the vulnerable-target
  Clopper-Pearson interval are now descriptive; resolvable-tier table for 73
  targets (best tier: moderate); chance arithmetic 1.37e-6 per route.
- 2026-10-21, clone_eval (owner decision, before any run): 251 extra target
  speakers (train-clean-100), targets only. Headline tier is the pooled
  324-target bound; dev and clone_eval are also reported separately.
  Thresholds and selection come from dev. Resolution table for 73 / 251 /
  324. The power check is now the betting lower bound (bootstrap
  descriptive). TitaNet caveat extended. Budget 8 GPU-hours.
- 2026-10-21, sol invert-r5 and clone-r3 fixes (owner decisions, before any
  run): the pooled headline is withdrawn.
  - Headline: **clone_eval alone**, with dev thresholds (independent
    calibration) and unique same-sex train partners as floors (independent
    across targets). Dev tiers are exploratory.
  - Betting-bound inversion rounds outward (grid plus bisection).
  - Targets are processed in a pre-registered seeded permutation
    (ORDER_SEED 7331).
  - The resolution table is qualified as covering constant zero-excess cases
    only.
  - `synth` refuses to run without a committed, matching selection log.
  - Strict selection parsing.
  - The enrollment anchor (W1 v2) is protected like the mean.
- 2026-10-21, sol invert-r6 (final invert round) and clone-r4 fixes, before
  any run. invert-r6:
  - #1 rejected by the orchestrator with a reason: the sampling design is stated, and U(a) is
    kept beside every tier;
  - #2 the floor wording is now "training-speaker baseline", with no claimed
    direction;
  - #3 resolution table recomputed by the implementation, rounded up, and
    test-regenerated;
  - #4 the anchor is protected once and stored byte-identically, and any
    anchored-rule experiment must test joint disclosure;
  - tiers are labelled with the achieved clone_eval FAR.

  clone-r4: append-only synthesis ledger with re-registration control,
  utility-budget evidence required in the selection log, `--max-gpu-hours`
  limit.
- 2026-10-21, post-final-round fixes (clone-r5; no further round, verified by
  the orchestrator): one canonical ledger and run directory; emitted tiers and
  the interpretation name the estimand "excess over the training-speaker
  baseline"; utility budget checked on full-precision values.
- 2026-10-21, third profile embedder (driven by W1's Stage A dev result, not
  by any W4 outcome; before any W4 result exists):
  - redimnet2-b2 is added with the same grid and becomes the primary
    embedder for the recommendation; ECAPA and TitaNet-s are secondary.
  - Cloning priority is redimnet2-b2, then ecapa-vox; titanet-s is dropped
    first if over budget.
  - The verifier dependency on W1's final pick is stated.
- 2026-10-21, owner decision after the inversion results: the cloning stage
  (section 6.4) is skipped and no synthesis is run in this experiment. The
  owner treats encryption at rest as the shipping protection; an attacker who
  can decrypt also holds the dictation audio, which is better cloning
  material. The committed selection log (d5460d9) records the plan that was
  not executed. H1 remains untested (RESULTS.md).
