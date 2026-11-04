# Parakeet startup

The app loads, warms and uses only the 15-second Core ML encoder function
(`b15`). The bundled model is kea-b-0.1, whose bundle holds only that
function. Sections before "Results: kea-b-0.1" measured the earlier kea-t
bundle, which also carried 4-, 8- and 30-second functions that were never
loaded. No second model, runtime, kernel payload, permission request or
production logging is added. The MLX experiment code has been removed.

Earlier versions prepared b15 first and then the other functions in the
background, choosing the smallest ready function per chunk and splitting
recordings at the largest ready one. Neural Engine memory is held per loaded
function, so all four functions cost about three times as much memory as
b15 alone (670 MB versus 209 MB of process plus Neural Engine memory on an
M1 Pro, measured with an experimental 1-bit encoder bundle; the shipped
ternary bundle was not measured separately). Recordings are transcribed while they are recorded, so after
release a dictation waits only for its last chunk of at most 15 seconds; a
smaller function would save little of that.

## Startup and recording length

`AppState.init` calls `prepareLocalTranscriptionIfNeeded()` before onboarding
permissions are granted. Preparation does not wait for microphone or
Accessibility permission, or the first dictation. The service's serial queue
loads b15 and warms it with synthetic zero input before marking it ready.
Repeated preparation is idempotent; a failed preparation is retried by the
next request, such as Settings' retry. Every chunk runs on b15, shorter
inputs through padding. Recordings are split into 15-second chunks that
overlap by 2 seconds and are joined on a word both heard; this does not
impose a 15-second recording limit.

kea-b-0.1's export SHA-256 is
`ec05526ed7aa7c742ee970c09724b1b8ccfaef6eb10f2ff1a11b031e9dfc4995`, and its
encoder is the plain-layout B1Q bundle that `scripts/prepare-parakeet.py`
builds. kea-t's was
`a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503` (C6s8).

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
paths. Output must be a new directory outside this Git checkout. Each repeat
gets a copied inference-only bundle at a new path, followed by a fresh process
using the same path. No cache is deleted.

The runner hash-verifies the bundle, builds an optimized standalone Swift
executable, generates an invented sentence with the installed Samantha voice,
and pads it to 2/4/7/14 seconds. The 18- and 33-second fixtures repeat the
sentence after long pauses, which silence compaction shortens before chunking.
Only match flags, timing statistics and function-bucket IDs are
printed. It never launches the app, records a microphone, reads user settings/history/context, or contacts
a transcription provider. Generated model copies and synthetic fixtures stay
outside Git. Existing metadata labeling normalizes the LocalFlow model ID
without changing trained weight bytes.

Copying the bundle, compiling the benchmark and generating speech are excluded
from startup timings. Runtime integrity verification, weight loading, device
specialization and the first inference are included. The runner verifies each
transcript and that every encoder pass used b15. The optional bucket observer
is installed only by the synthetic harness; the app records nothing.

## Results: kea-b-0.1, shared M1 Pro, macOS 27.0, 2026-11-03

[The timing record](parakeet-startup-results-kea-b-0.1.json) has one repeat.
Times run from CLI initialization to the first matched transcript.

| Initial preparation | New-path first transcript | Same-path fresh-process first transcript | New-path peak group RSS |
| --- | ---: | ---: | ---: |
| 15-second ANE function | 30.19 s | 1.30 s | 248 MiB |

Every synthetic fixture matched, including the 18- and 33-second recordings
that need more than one chunk. kea-t's 15-second-only arm took 94.27 s and
0.83 s in the 2026-10-05 run below; that run used an earlier harness, so the
comparison is indicative only.

## Results: kea-t, shared M1 Pro, macOS 27.0, 2026-10-05

Superseded: this section measured runtimes that loaded more than one
function, with the earlier harness arms (`all`, `fifteen-first`,
`fifteen-background`).

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

## Progressive preparation

Two later one-repeat runs on the same M1 Pro prepared b15 first and the other
functions in the background: first b2/b4/b8/b15, then the b4/b8/b15/b30
functions the bundle still carries. Version 2.1.7 removed that setup; its
timing records were deleted later.

## Stable model location

Core ML's on-device specialization cache (per app, per OS build, per
function) is keyed by `Encoder.mlmodelc/weights/weight.bin`'s path and inode,
not its content or timestamps. On the shared M1 Pro (macOS 27.0, 2026-10-17),
b4 loaded in about 100–117 s cold and 0.4–4 s warm. The load was cold after
any of these:

- replacing the files in place with an identical copy (an app update)
- `cp -Rp`, which keeps timestamps
- an APFS clone to a new path
- `mv`
- re-creating a previously warm path
- replacing only `weight.bin`

It stayed warm after `touch` of any file or replacing `model.mil` or
`coremldata.bin`.

`ParakeetModelStore` therefore loads the model from
`<Application Support>/<bundle identifier>/Models/<SHA-256 of bundle.json>/`
on macOS. There, a rebuilt executable or the same executable at a new path
also stayed warm. iOS keeps loading from the bundle, because a stable copy
does not survive its updates. On TestFlight 18 → 19, a copy in Application
Support survived the update, but Core ML computed a new cache key and
compiled again (iOS moves the app's data container). On TestFlight 20 → 21,
a copy in the App Group container kept its model cache entry, yet the Neural
Engine program was compiled again for the new build. Both measurements used
an iPhone 15 Pro on iOS 26.
It installs that directory once, by an APFS clone into a staging directory
and a rename, and never rewrites it. A copy is used only if its `bundle.json`
still hashes to the directory name, so the integrity check never trusts a
manifest that differs from the bundle's. Other entries under `Models` are
removed. Any failure falls back to the bundle, including a store copy that
fails the integrity check or Core ML's first load. The clone shares the
bundle's blocks until an update replaces the bundle; then the store costs
about the bundle's size (138 MB for kea-b-0.1, 370 MB for kea-t).

In a synthetic smoke run of the real service with a temporary store, b15
preparation took 216.96 s on the first process (install plus cold, on a busy
machine) and 2.14 s on the second. After the source bundle was replaced at the
same path by a fresh `cp -R` copy, the third process took 2.88 s; the store's
`weight.bin` kept its inode.

## Validation limits

New-path loads are not proven cold device-cache loads: no cache deletion or
Instruments cache events were used. A fresh process does not imply a fresh ANE
specialization cache. These are synthetic smoke measurements on a shared Mac,
not a controlled performance study, WER evaluation or sustained speech test.
The padded fixtures contain short speech, with lighter decoder work than fully
voiced recordings. Guard RSS polling can miss peaks and excludes system
services. Normal desktop work and a brief verification build overlapped the run.

Regression tests cover loading and warming only b15, idempotent preparation,
retry after a failed load or warm-up, prepared-model reuse, b15 for 2- to
15-second inputs and 15-second chunks with a 2-second overlap for longer
recordings. `make check` and `git diff --check` are required. The harness does not verify microphone permissions, shortcuts,
Accessibility paste or real-user audio; it does not change app permissions.
