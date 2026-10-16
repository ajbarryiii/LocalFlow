# LocalFlow and Apple speech recognition

This compares the bundled LocalFlow model (the ternary Parakeet v2
derivative, base model label `kea-t`) with Apple's two on-device English
recognizers on the public LibriSpeech test sets:

- **SpeechTranscriber**, part of the SpeechAnalyzer framework introduced in
  macOS 26 and iOS 26. Its English model is a shared system asset.
- **SFSpeechRecognizer**, the older Speech framework API, with
  `requiresOnDeviceRecognition` set so that no audio leaves the Mac.

All three run locally. No audio, transcripts or results from a real user are
involved, and nothing is sent to a provider.

## Results

M1 Pro, macOS 27.0, 2026-10-15. Every utterance of both sets; no engine
failed or returned empty text. [The aggregate record](apple-speech-results.json)
holds the full statistics. Word error rate, lower is better, with 95% bootstrap
intervals:

| Engine | test-clean | test-other |
| --- | ---: | ---: |
| LocalFlow | 2.06% (1.89–2.23) | **4.32%** (4.07–4.57) |
| SpeechTranscriber | **1.87%** (1.71–2.03) | 4.36% (4.11–4.61) |
| SFSpeechRecognizer, on-device | 8.65% (8.05–9.26) | 16.18% (15.43–16.91) |

Paired against LocalFlow on the same utterances, SpeechTranscriber is 0.19
points better on test-clean (95% interval 0.06–0.32) and indistinguishable on
test-other (+0.04, −0.16 to +0.22). SFSpeechRecognizer is 6.6 and 11.9 points
worse. LocalFlow's 4.42% on test-other with the word-boosting normalizer agrees
with the 4.41% baseline in [the word-boosting notes](../docs/word-boosting.md).

Without the spelling map, the two leading engines score 2.21%/4.42% (LocalFlow)
and 2.00%/4.47% (SpeechTranscriber); the ranking does not change.

Processing time per utterance from the same run. The Mac was shared with
other build jobs under heavy memory pressure, so treat these as indicative.
The real-time factor is processing time divided by audio duration:

| Engine | Real-time factor (clean / other) | Median per utterance (clean / other) |
| --- | ---: | ---: |
| LocalFlow | 0.009 / 0.009 | 0.045 s / 0.041 s |
| SpeechTranscriber | 0.030 / 0.031 | 0.173 s / 0.158 s |
| SFSpeechRecognizer | 0.052 / 0.064 | 0.293 s / 0.305 s |

LocalFlow runs in the benchmark process with its model already prepared.
Apple's recognizers run in a system service, and each file starts a new
recognition session, which is how an app would use them for separate
dictations. The timings include that overhead; the split between overhead and
inference was not measured.

| | On disk | Shipped as |
| --- | ---: | --- |
| LocalFlow model | 367 MB | inside the app |
| SpeechTranscriber English model | about 200 MB | shared system asset, downloaded once |

Apple's asset directory reports 395 MB, but holds what appear to be a packed and
an unpacked copy of the same 190–204 MB of model files; a separate 16 MB
language-identification asset is also installed.

## Method

[`scripts/benchmark-apple-speech.py`](../scripts/benchmark-apple-speech.py)
builds [`scripts/apple-speech-benchmark.swift`](../scripts/apple-speech-benchmark.swift)
with `Sources/Parakeet` and `Sources/Dictionary` into a small ad hoc signed app.
macOS attributes the Speech Recognition permission to an app bundle, so the
driver launches it through LaunchServices. The harness never opens LocalFlow,
the microphone, its settings or history, the clipboard or the network.

- **Audio:** every utterance in LibriSpeech test-clean (2,620 utterances,
  5.4 h) and test-other (2,939 utterances, 5.3 h), as distributed by OpenSLR.
- **LocalFlow:** a copy of the model bundle from the installed app, export
  SHA-256 `a287e977…1503`, decoded without a dictionary. Timing starts after
  every encoder function (4/8/15/30 s) is prepared, matching steady-state
  dictation. App-level text rules such as spoken-number formatting are not
  applied; this measures the model.
- **SpeechTranscriber:** `en-US`, preset `.transcription` (final results only),
  one new `SpeechAnalyzer` per file with model retention for the process.
- **SFSpeechRecognizer:** `en-US`, on-device only, punctuation on, final
  result only.
- **Timing:** wall-clock from the audio file URL to the final text, one
  utterance at a time, after one untimed warmup. Real-time factor is total
  processing time divided by total audio duration; lower is faster.
- **Scoring:** word error rate over the whole set. Both reference and output
  are lowercased with punctuation removed; digits, currency, percentages and
  Mr/Mrs/Dr are spelled out the way LibriSpeech writes them; and British
  spellings are mapped to American ones with Whisper's spelling list, as the
  Open ASR Leaderboard does. The list is downloaded at a pinned commit and
  hash-checked. 95% intervals come from 1,000 bootstrap resamples of
  utterances; differences against LocalFlow are paired on the same utterances.
  `results.json` also records WER without the spelling map and with the
  case-and-punctuation-only normalizer used in
  [the word-boosting notes](../docs/word-boosting.md).

## Reproduce

Apple Silicon, macOS 26 or later, Python 3.9 or later, Xcode command-line tools.
Download and extract `test-clean.tar.gz` and `test-other.tar.gz` from
<https://www.openslr.org/12> into one directory, then:

```sh
python3 scripts/benchmark-apple-speech.py \
  --bundle "$MODEL_BUNDLE" \
  --librispeech "$LIBRISPEECH_PARENT" \
  --output "$NEW_ARTIFACT_DIRECTORY"
```

The output directory must be outside this checkout. It receives the model copy,
the benchmark app, per-engine hypotheses and `results.json`; an interrupted run
resumes. `--limit N` runs the first N utterances of each set. The first
SFSpeechRecognizer run asks for Speech Recognition permission, and
SpeechTranscriber may download Apple's English assets.

## Limitations

LibriSpeech is read audiobook speech. It is not dictation, and both test sets
are far cleaner than a laptop microphone in a meeting room. NVIDIA's model
card lists LibriSpeech (960 hours) among Parakeet v2's training data, and
reports 1.69% and 3.19% WER on test-clean and test-other for the full-precision
model. In-domain training may favour LocalFlow on these sets. Apple's training
data is not public.
