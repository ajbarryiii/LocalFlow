# Progressive Parakeet startup

This branch prepares the 15-second Core ML function first at app launch,
using the same completed 250,000-step ternary Parakeet checkpoint already
shipped with the app. After initial readiness, it prepares the smaller functions
on a separate queue and adopts each successful result. The earlier cold-start
app tested only the first stage; this progressive version needs manual app
testing. No second model, runtime, kernel payload, permission request or
production logging is added. The MLX experiment code has been removed.

## Startup and recording length

`AppState.init` calls `prepareLocalTranscriptionIfNeeded()` before onboarding
permissions are granted. Preparation does not wait for microphone or
Accessibility permission, or the first dictation. The service's serial queue
warms the 15-second function with synthetic zero input before marking it ready.
Dictation initially uses this prepared function, including shorter inputs through
padding. As smaller functions finish warming, each chunk uses the smallest
ready function large enough for its input. Longer recordings retain the existing
independent 15-second chunks; this does not impose a 15-second recording limit or improve
boundary context.

A utility queue loads and warms separate 2/4/8-second encoder instances, one
at a time. A successful warmup hands its model to the foreground queue for
installation; that queue alone owns the cache, frontend, decoder and routing.
Thus background compilation does not occupy the dictation queue. Shared CPU,
Core ML and ANE resources can still affect latency and must be measured.
Failures preserve the ready functions and do not change the app's ready state;
a later explicit service preparation request retries only failed background
functions. Runtime replacement cancels pending work and discards an in-flight
result from the old runtime. Active synchronous Core ML calls must finish.

The harness can select `all` (previous all-function startup), `fifteen-first`
(the earlier test without optimization) or `fifteen-background` (this progressive
policy). The application's default is `fifteen-background`. Repeated initial
preparation is idempotent and does not duplicate an active background pass.

The final checkpoint export SHA-256 is
`a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503`.
The existing C6s8 compiled bundle and frontend/decoder/vocabulary remain unchanged.

## Reproduce

Run on Apple Silicon, macOS 26 or later, with Python 3.9 or later and the
upstream `wilderness-labs-stt/finetune/parakeet-ternary/ios/macguard` launcher.
No additional Python packages are required.

```sh
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" make check
git diff --check
python3 scripts/benchmark-parakeet-startup.py \
  --bundle "$MODEL_BUNDLE" \
  --output "$NEW_ARTIFACT_DIRECTORY" \
  --guard "$IOS/macguard"
```

`IOS`, `MODEL_BUNDLE`, and `NEW_ARTIFACT_DIRECTORY` refer to existing local
paths. Output must be a new directory outside this Git checkout. The default
arms are `all`, `fifteen-first` and `fifteen-background`; `--repeats 2` reverses
their order on the second repeat. Each arm gets a copied inference-only bundle at a new path,
followed by a fresh process using the same path. No cache is deleted.

The runner hash-verifies the bundle, builds an optimized standalone Swift
executable, generates an invented sentence with the installed Samantha voice,
and pads it to 2/4/7/14 seconds. The 18-second fixture repeats the sentence across
two chunks. Only match flags, timing statistics and function-bucket IDs are
printed. It never launches the app, records a microphone, reads user settings/history/context, or contacts
a transcription provider. Generated model copies and synthetic fixtures stay
outside Git. Existing metadata labeling normalizes the LocalFlow model ID
without changing trained weight bytes.

Copying the bundle, compiling the benchmark and generating speech are excluded
from startup timings. Runtime integrity verification, weight loading, device
specialization and the first inference are included. The progressive arm keeps
transcribing generated fixtures once per second during remaining preparation,
then verifies successful transcripts and actual function selection after handoff:
2s → b2, 4s → b4, 7s → b8, 14s → b15, and 18s → b15 plus b4. The optional
bucket observer is installed only by the synthetic harness; the app records
nothing. The report also includes readiness snapshots, background sample count,
median/p95/maximum latency and completion time.

## Results: shared M1 Pro, macOS 27.0, 2026-10-05

[The timing record](parakeet-startup-results.json) contains the Core ML runs.
Times below run from CLI initialization to the first matched transcript.

| Initial preparation | New-path first transcript | Same-path fresh-process first transcript | New-path peak group RSS |
| --- | ---: | ---: | ---: |
| All four ANE functions | 372.04 s | 2.28 s | 450 MiB |
| 15-second ANE function only | 94.27 s | 0.83 s | 489 MiB |

Every synthetic fixture matched, including the 18-second two-chunk recording.
The 15-second-only arm's prepared transcription times were 58–85 ms for single
chunks and 114 ms for two chunks in the new-path run.

The user tested the same startup override in an isolated app: readiness took
approximately 90 seconds, while permission setup took only 10–15 seconds.
Starting preparation at launch therefore hides only a small part of the
first-use delay. This change reduces startup work but does not make first-use
dictation immediate.

## Progressive preparation validation

[The progressive timing record](parakeet-background-results.json) is a separate
one-repeat run on the same M1 Pro. The new-path first transcript was ready in
92.11 seconds; only b15 was prepared at initial readiness. The remaining
functions completed by 360.72 seconds, while dictation remained usable.
235 mixed-length synthetic dictations during optimization all matched, with
89.8 ms median, 153.8 ms p95 and 192.9 ms maximum latency. Traces included
b2 and b4 during the remaining background work. Final checks confirmed b2,
b4 and b8 selection, and b15+b4 for the 18-second two-chunk fixture.

A fresh process reusing that model path produced its first transcript in
0.79 seconds and completed optimization by 2.17 seconds. All initial,
background and post-handoff fixtures matched; repeated preparation took less
than a millisecond. The guarded process group peaked at 554 MiB for the
new-path run and 241 MiB for same-path reuse, with no swap growth. System
Core ML/ANE services are excluded. These are smoke results, not a promise
of unchanged foreground latency on every machine.

## Validation limits

New-path loads are not proven cold device-cache loads: no cache deletion or
Instruments cache events were used. A fresh process does not imply a fresh ANE
specialization cache. These are synthetic smoke measurements on a shared Mac,
not a controlled performance study, WER evaluation or sustained speech test.
The padded fixtures contain short speech, with lighter decoder work than fully
voiced recordings. Guard RSS polling can miss peaks and excludes system
services. Normal desktop work and a brief verification build overlapped the run.

Regression tests cover default bootstrap routing, foreground progress during
a blocked background warmup, atomic installation, failure/retry, duplicate-start
prevention, cancellation of an obsolete runtime and prepared-model reuse. `make check` and `git diff --check` are
required. The harness does not verify microphone permissions, shortcuts,
Accessibility paste or real-user audio; it does not change app permissions.
