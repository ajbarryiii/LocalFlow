# Bundled LocalFlow speech model

LocalFlow's model, kea-b-0.1, is a 1-bit derivative of NVIDIA Parakeet v2. It
is Kea-B′, run `b100-main` of stage 4 of the relabel work in
`ajbarryiii/wilderness-labs-stt`: kea-b (the binary run `main-binB-m1-lr2e-4`
at step 250,000) trained for 97,137 more steps on transcripts from a stronger
teacher, with 8-bit decoder weights. Its `parakeet-binary-v1` export SHA-256 is
`ec05526ed7aa7c742ee970c09724b1b8ccfaef6eb10f2ff1a11b031e9dfc4995`. This is an
English speech model. `NOTICE` lists its changes, training data and labels.

Inference uses a plain-layout B1Q Core ML encoder with only the 15-second
function (`b15`), `cpuAndNeuralEngine`, a native vDSP feature extractor, and
the native FP32 Accelerate TDT decoder (F2). B1Q stores each binary projection
as 1-bit codes expanded through a {-1, +1} lookup table, then multiplied by an
FP16 per-row scale. The encoder graph uses FP16 values; the decoder remains
FP32. The generated model targets macOS 26 or newer.

On a shared M1 Pro (macOS 27.0, 2026-11-03), through LocalFlow's own runtime
on 150 test-clean and 150 test-other LibriSpeech utterances, kea-b-0.1 had a
WER of 1.98% and 4.12%, against 1.98% and 4.30% for the earlier kea-t. Its
bundle is 138 MB against kea-t's 384 MB, and process plus Neural Engine memory
after loading was 222–286 MB against 442 MB. The warm 15-second encoder call
took 59.2 ms against 49.5 ms: the Neural Engine skips kea-t's zero weights,
and binary weights have none. End-to-end transcription times were within 1%.
These are informational measurements on a shared machine.

Native source adaptations come from the upstream `parakeet-ios` branch at
commit `79f0b0a42f3be518ff52da3980fa53e0f10816f2`. The bundle is built by the
upstream 1-bit converter, `finetune/parakeet-binary-coreml/prepare_bundle.py`
at commit `396df9869c03600381d5c9566e67886997ffb982`. Only inference code is
included; diagnostic capture and benchmark record writing are excluded.

This fork uses the bundled Parakeet model exclusively. No provider credentials,
model selector, network transcription, realtime socket, LLM cleanup, translation,
Edit Mode, or app/screenshot context capture is included. English dictation,
deterministic voice macros, local history/retry, and paste behavior remain.
Microphone and Accessibility are the only dictation permissions.

The app loads, warms and uses only the 15-second encoder function (`b15`),
the only function the bundle holds. The Neural Engine holds memory for every
loaded function, and with transcription while recording a smaller function
would save at most one short chunk's encoder time after release. Settings offers a retry when preparation fails.
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
the pinned export using the upstream pinned Mac Python environment. Run it
through the upstream `ios/macguard`, with `--upstream STT_CHECKOUT` (at the
converter commit above), `--export KEA_B_EXPORT`, and `--output MODEL_BUNDLE`.
Output must be in the upstream's allowed artifact area. It verifies the export
and tokenizer hashes and writes a bundle manifest with per-file SHA-256
hashes. Runtime verifies those hashes before loading. Preserve the generated
bundle outside the checkout.

The converter sizes the folded relative-position table for the 15-second
function's 188 encoder frames. The earlier kea-t bundle also carried 4-, 8-
and 30-second functions that the app never loaded; leaving them out saves
52 MB, and the 15-second function's outputs are bitwise identical either way.

The bundle model ID is `localflow`, with display name LocalFlow and
`kea-b-0.1` recorded as its base model. The build relabels the copied bundle
after verifying its existing hashes; only metadata and the corresponding
hashes change. Encoder and decoder weights are unchanged. The build refuses
any bundle whose export is not kea-b-0.1's, so no other weights ship under
this notice.

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

Deterministic tests cover the runtime without the model: only the 15-second
function is loaded and warmed, preparation is idempotent and reused by
transcription, a failed load or warm-up is retried, and recordings of any
length are split into 15-second chunks with a 2-second overlap. They also
cover token boundaries, duration-zero progress, symbol caps, cancellation,
native blob bounds, silent features, and synthetic stereo AIFF resampling
through EOF. Startup timing on a shared M1 Pro is in
`Benchmarks/ParakeetStartup.md`.

Microphone dictation, global shortcuts, Accessibility paste, cancellation,
local retries and offline operation are checked by hand in a built app.
