# Bundled Parakeet v2 ternary

The model is the completed `main-M1-P2-lr5e-4` training run from
`ajbarryiii/wilderness-labs-stt`, selected at step 250,000. Its packed export
SHA-256 is `a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503`.
The full development-set mean WER reported after rebuilding that export is
6.0856%. This is an English speech model.

Inference uses the M1 Pro optimization experiment's plain-layout C6s8
multifunction Core ML encoder, with 2/4/8/15-second functions,
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

In FreeFlow, select `parakeet-v2-ternary` under Settings → Models →
Transcription Model, with English or Auto-detect. Setup also offers the
bundled model without an API key. Dictation bypasses cloud transcription,
realtime streaming, context analysis, cleanup, translation, and Edit Mode.
Existing local history and paste behavior still apply. There is no automatic
cloud fallback when local inference fails. Other explicit provider tests in
Settings retain their existing behavior.

The first use of each bucket may take several minutes while Core ML prepares
the model for the device. Subsequent uses reuse the loaded model. Recordings
longer than 15 seconds are split into independent chunks; words crossing a
chunk boundary can lose context. Cancellation is checked between audio
buffers, Core ML calls, and decoder steps; an in-progress Core ML load or
prediction must finish before cancellation returns.

Weights are not stored in Git. `scripts/prepare-parakeet.py` converts only
the pinned final export using the upstream pinned Mac Python environment.
Run it through the upstream `ios/macguard`, with `--upstream STT_CHECKOUT`,
`--export FINAL_EXPORT`, and `--output MODEL_BUNDLE`. Output must be in the
upstream's allowed artifact area. It verifies the export hash and writes a
bundle manifest with per-file SHA-256 hashes. Runtime verifies those hashes
before loading. Preserve the generated bundle outside the checkout.

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
cancellation, native blob bounds, provider routing, silent features, and
synthetic stereo AIFF resampling through EOF. The separate synthetic speech
smoke check exercises the converted final model without launching FreeFlow
or requesting microphone access.

All four encoder buckets transcribed the invented phrase exactly. An
18-second synthetic recording with the phrase in both chunks also matched
exactly. First-use smoke runs took 98–109 seconds including model preparation;
the subsequent 18-second run completed in about one second. These are
functional checks, not a controlled performance benchmark or real-world
accuracy evaluation.

Before merge, manually test microphone dictation, global shortcuts,
Accessibility paste, cancellation, switching providers, and offline operation
in the built app. These app-level checks remain pending; the local build is
ad hoc signed and has not been notarized or released.
