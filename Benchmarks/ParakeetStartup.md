# Parakeet 15-second-first startup

LocalFlow now prepares only the 15-second Core ML function at app launch,
using the same completed 250,000-step ternary Parakeet checkpoint already
shipped with the app. This is the behavior of the manually tested cold-start
app. No second model, runtime, kernel payload, permission request or production
logging is added. The MLX experiment code has been removed.

## Startup and recording length

`AppState.init` calls `prepareLocalTranscriptionIfNeeded()` before onboarding
permissions are granted. Preparation does not wait for microphone or
Accessibility permission, or the first dictation. The service's serial queue
warms the 15-second function with synthetic zero input before marking it ready.
Dictation then uses this prepared function for the session, including shorter
inputs through padding. Longer recordings retain the existing independent
15-second chunks; this does not impose a 15-second recording limit or improve
boundary context.

The app does not start smaller-function warmups after becoming ready. A Core
ML load/prediction cannot be preempted, so doing that work on the dictation queue
could reintroduce long stalls. The comparison harness can still explicitly
select the previous all-function startup. Successful preparation is reused;
failed preparation can be retried without displacing an already usable model.

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
arms are `all` and `fifteen-first`; `--repeats 2` reverses their order on the
second repeat. Each arm gets a copied inference-only bundle at a new path,
followed by a fresh process using the same path. No cache is deleted.

The runner hash-verifies the bundle, builds an optimized standalone Swift
executable, generates an invented sentence with the installed Samantha voice,
and pads it to 4/7/14 seconds. The 18-second fixture repeats the sentence across
two chunks. Only match flags and timings are printed. It never launches the
app, records a microphone, reads user settings/history/context, or contacts
a transcription provider. Generated model copies and synthetic fixtures stay
outside Git. Existing metadata labeling normalizes the LocalFlow model ID
without changing trained weight bytes.

Copying the bundle, compiling the benchmark and generating speech are excluded
from startup timings. Runtime integrity verification, weight loading, device
specialization and the first inference are included.

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

## Validation limits

New-path loads are not proven cold device-cache loads: no cache deletion or
Instruments cache events were used. A fresh process does not imply a fresh ANE
specialization cache. These are synthetic smoke measurements on a shared Mac,
not a controlled performance study, WER evaluation or sustained speech test.
The padded fixtures contain short speech, with lighter decoder work than fully
voiced recordings. Guard RSS polling can miss peaks and excludes system
services. Normal desktop work and a brief verification build overlapped the run.

Regression tests cover default bootstrap routing, smaller-function preparation
failure/retry and prepared-model reuse. `make check` and `git diff --check` are
required. The harness does not verify microphone permissions, shortcuts,
Accessibility paste or real-user audio; it does not change app permissions.
