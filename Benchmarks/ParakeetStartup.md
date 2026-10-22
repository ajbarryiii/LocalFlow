# Parakeet startup

The app loads, warms and uses only the 15-second Core ML encoder function
(`b15`), using the same completed 250,000-step ternary Parakeet checkpoint
already shipped with the app. The bundle still contains 4-, 8- and 30-second
functions; they are never loaded. No second model, runtime, kernel payload,
permission request or production logging is added. The MLX experiment code
has been removed.

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

## Results: shared M1 Pro, macOS 27.0, 2026-10-05

Superseded: this and the next two sections measured runtimes that loaded more
than one function, with the earlier harness arms (`all`, `fifteen-first`,
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

## 4/8/15/30-second functions

The encoder was reconverted from the same export with b4/b8/b15/b30 functions
in place of b2/b4/b8/b15. Startup still prepares b15 first, then warms b4, b8
and b30 in the background. Recordings split at the largest ready function.
[The timing record](parakeet-b30-results.json) is a one-repeat run on the same
M1 Pro, with an added 33-second fixture whose phrases cross the 15-second
split, end near the 30-second window edge and fall in the remainder chunk.

The new-path first transcript was ready in 102.51 seconds with only b15
prepared; all four functions were ready by 421.24 seconds. Before b30 was
ready, the 18- and 33-second fixtures used 15-second chunks. 271 synthetic
dictations during optimization all matched: 97.7 ms median, 251.0 ms p95
and 267.2 ms maximum. After optimization, 2/4/7/14-second fixtures used
b4/b4/b8/b15, the 18-second fixture used a single b30 pass in 250 ms, and the
33-second fixture used b30+b4 in 216 ms; all matched.

A fresh process reusing that model path produced its first transcript in
0.87 seconds and completed optimization by 2.52 seconds, with all fixtures
matching. The guarded process group peaked at 582 MiB for the new-path run
and 340 MiB for same-path reuse. The compiled encoder grew from 299 MB to
332 MB because the shared position tables cover 30 seconds. The b30 function
has no upstream accuracy gate; these checks are synthetic smoke results only.

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
about 370 MB.

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
