# Bundled LocalFlow speech model

LocalFlow is the ternary derivative of NVIDIA Parakeet v2 from the completed `main-M1-P2-lr5e-4` training run from
`ajbarryiii/wilderness-labs-stt`, selected at step 250,000. Its packed export
SHA-256 is `a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503`.
The full development-set mean WER reported after rebuilding that export is
6.0856%. This is an English speech model.

Inference uses the M1 Pro optimization experiment's plain-layout C6s8
multifunction Core ML encoder, with 4/8/15/30-second functions of which the
app runs only the 15-second one,
`cpuAndNeuralEngine`, a native vDSP feature extractor, and the native FP32
Accelerate TDT decoder (F2). C6s8 stores a sparse mask and grouped ternary
lookup tables. The encoder graph uses FP16 values and FP16-rounded row scales;
the decoder remains FP32. The generated model targets macOS 26 or newer.

The prior WP7 experiment used **pilot P2 weights**, not this final export.
Its paired results on a shared M1 Pro were informational: total latency was
0.34/0.39/0.52/0.77 times the published Core ML baseline for 2/4/8/15 seconds.
Plain C6s8 outperformed its ANE-layout variant; GPU configurations were slower.
Those figures and the pilot's numerical eligibility records do not establish
performance or accuracy of this newly converted final model.

Native source adaptations come from the upstream `parakeet-ios` branch at
commit `79f0b0a42f3be518ff52da3980fa53e0f10816f2`. The relevant experiment
documentation is `finetune/parakeet-ternary/ios/README.md`, sections WP4 and
WP7. Only inference code is included; diagnostic capture and benchmark
record writing are excluded.

This fork uses the bundled Parakeet model exclusively. No provider credentials,
model selector, network transcription, realtime socket, LLM cleanup, translation,
Edit Mode, or app/screenshot context capture is included. English dictation,
deterministic voice macros, local history/retry, and paste behavior remain.
Microphone and Accessibility are the only dictation permissions.

The app loads, warms and uses only the 15-second encoder function (`b15`).
The bundle's 4-, 8- and 30-second functions are never loaded: the Neural
Engine holds memory for every loaded function, and with transcription while
recording a smaller function would save at most one short chunk's encoder
time after release. Settings offers a retry when preparation fails.
Preparation loads the 15-second encoder function on the dictation queue and
runs a synthetic zero-input prediction, without accessing the microphone or
user content.
Settings and the menu show preparation status. First-time device preparation
may still take several minutes; dictation submitted before it finishes waits
behind preparation. The runtime and loaded models stay in memory for the
session, so subsequent dictations reuse them. The model's file size is not its runtime RAM footprint: loaded models
and working buffers require additional memory. Recordings are split into
15-second chunks that overlap by 2 seconds, each padded to the 15-second
function; overlapping chunks are joined on a word both heard. Words crossing
a chunk boundary can lose context. Cancellation is checked between audio
buffers, Core ML calls, and decoder steps; an in-progress Core ML load or
prediction must finish before cancellation returns.

Weights are not stored in Git. `scripts/prepare-parakeet.py` converts only
the pinned final export using the upstream pinned Mac Python environment.
Run it through the upstream `ios/macguard`, with `--upstream STT_CHECKOUT`,
`--export FINAL_EXPORT`, and `--output MODEL_BUNDLE`. Output must be in the
upstream's allowed artifact area. It verifies the export hash and writes a
bundle manifest with per-file SHA-256 hashes. Runtime verifies those hashes
before loading. Preserve the generated bundle outside the checkout.

The upstream experiment built 2/4/8/15-second functions. `prepare-parakeet.py`
replaces that bucket set with 4/8/15/30 seconds for this conversion only (the
app now runs only the 15-second function), and
extends the shared folded relative-position tables from 188 to 376 encoder
frames. Shorter functions slice the same centre positions, whose values depend
only on position. The upstream accuracy gates did not cover the 30-second
function; its synthetic smoke validation is in `Benchmarks/ParakeetStartup.md`.

The bundle model ID is `localflow`, with display name LocalFlow and
`kea-t` recorded as its base model. The build can relabel a
previous Parakeet bundle after verifying its existing hashes; only metadata
and the corresponding hashes change. Encoder and decoder weights are unchanged.

Build locally with:

```sh
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" make check
git diff --check
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" make \
  ARCH="$(uname -m)" CODESIGN_IDENTITY=- PARAKEET_BUNDLE_DIR="MODEL_BUNDLE"
```

Bundled builds enable Swift `-O` so the native decoder is optimized, matching
the experiment. The build copies only the inference assets and these notices
into `Contents/Resources/Parakeet` before the existing signing step.
`LICENSE` and `NOTICE` cover the modified CC-BY-4.0 model;
`Software-LICENSE` covers the adapted MIT inference code.

Local validation on 2026-10-04: full Swift type-check and deterministic
tests, including token boundaries, duration-zero progress, symbol caps,
cancellation, native blob bounds, silent features, and
synthetic stereo AIFF resampling through EOF. The separate synthetic speech
smoke check exercises the converted final model without launching LocalFlow
or requesting microphone access.

All four encoder buckets transcribed the invented phrase exactly. An
18-second synthetic recording with the phrase in both chunks also matched
exactly. First-use smoke runs took 98–109 seconds including model preparation;
the subsequent 18-second run completed in about one second. These are
functional checks, not a controlled performance benchmark or real-world
accuracy evaluation.

The next three paragraphs describe earlier runtimes that loaded more than
one function; they are superseded by the 15-second-only runtime (see
`Benchmarks/ParakeetStartup.md`) and kept as a record.

Previous all-function startup validation on the same Mac: preparing all four buckets
using the existing Core ML device cache took 2.605 seconds, repeating
preparation took less than a millisecond, and the synthetic 18-second
two-chunk recording still matched exactly in 0.140 seconds after preparation.
The guarded process group peaked at about 153 MiB RSS; this does not include
all memory used by system Core ML/Neural Engine services. A fresh device cache
was not measured in this follow-up.

The earlier 15-second-only startup was tested by the user in an isolated
app: approximately 90 seconds to readiness, with only 10–15 seconds of setup.
The Core ML comparison and synthetic short/long transcript checks are documented
in `Benchmarks/ParakeetStartup.md`.

The 4/8/15/30-second conversion matched every synthetic fixture, including an
18-second recording in one b30 pass and a 33-second recording as b30+b4.
First-use readiness was 102.51 seconds with b15 only; all functions were ready
by 421.24 seconds.

Deterministic tests verify that only the 15-second function is loaded and
warmed, that preparation is idempotent and reused by transcription, that a
failed load or warm-up is retried, and that recordings of any length are
split into 15-second chunks with a 2-second overlap.

Before merge, manually test microphone dictation, global shortcuts,
Accessibility paste, cancellation, local retries, and offline operation
in the built app. These app-level checks remain pending; the local build is
ad hoc signed and has not been notarized or released.
